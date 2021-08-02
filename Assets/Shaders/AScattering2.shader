Shader "Universal Render Pipeline/Custom/AScattering2"
{
    Properties
    {
        [MainColor] _BaseColor("BaseColor", Color) = (1,1,1,1)
        [MainTexture] _MainTex("Main Tex", 2D) = "white" {}
    	_ScatteringPoints("ScatteringPoints", int) = 10
    	_OpticalDepthPoints("Optical Depth Points", int) = 10
    	_DensityFalloff("Density Falloff", float) = 10
    	_PlanetSize("Planet Size", float) = 3
    	_PlanetLocation("Planet Location", Vector) = (0,0,0, 0)
    	_AtmosphereHeight("Atmosphere Height", Range(0,10)) = 1
    	_DepthDistance("Depth Distance", float) = 100
    	_SunLightScattering("Sun Light Scattering", Range(0,1)) = 0.5
    	_VolumetricShadowPower("Shadow Power", float) = 1
    }

    SubShader
    {
        Tags { "RenderType"="Opaque" "RenderPipeline"="UniversalRenderPipeline"}

        // Include material cbuffer for all passes. 
        // The cbuffer has to be the same for all passes to make this shader SRP batcher compatible.
        HLSLINCLUDE
        
        
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/SurfaceInput.hlsl"
        #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"
        CBUFFER_START(UnityPerMaterial)
        float4 _BaseMap_ST; 
        half4 _BaseColor;
        CBUFFER_END

        ENDHLSL

        Pass
        {
            Tags { "LightMode"="UniversalForward" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS_CASCADE
            struct Attributes
            {
                float4 positionOS   : POSITION;
                float2 uv           : TEXCOORD0;
            };

            struct Varyings
            {
                float4 uv           : TEXCOORD0;
                float4 positionHCS  : SV_POSITION;
                float3 viewVector : TEXCOORD1;
                float3 positionWS : TEXCOORD2;
                float3 positionOS : TEXCOORD3;
            	float3 worldPos : TEXCOORD4;
            };

            TEXTURE2D(_MainTex);
            SAMPLER(sampler_MainTex);
            
            TEXTURE2D(_CameraDepthTexture);
            SAMPLER(sampler_CameraDepthTexture);

            int _ScatteringPoints;
            int _OpticalDepthPoints;
            float _DensityFalloff;
            float _PlanetSize;
            float _AtmosphereHeight;
            float _DepthDistance;			
            float3 _PlanetLocation;			

            float atmosphereScale;
			float4 scatteringCoefficients;
            
			float3 sunDirection;
            float _SunLightScattering;
            float _VolumetricShadowPower;
            
            Varyings vert(Attributes IN)
            {
                Varyings OUT;
            	VertexPositionInputs positionInputs = GetVertexPositionInputs(IN.positionOS.xyz);
                OUT.positionHCS = TransformObjectToHClip(IN.positionOS.xyz);
                // OUT.positionWS = TransformObjectToWorld(IN.positionOS.xyz); 
                OUT.positionWS = positionInputs.positionWS;
                OUT.positionOS = IN.positionOS.xyz;
                // OUT.uv.xy = TRANSFORM_TEX(IN.uv, _BaseMap);
				OUT.uv.xy = UnityStereoTransformScreenSpaceTex(IN.uv);
            	float4 projPos = OUT.positionHCS * 0.5;
				OUT.uv.zw = projPos.xy;
                float3 viewVector = mul(unity_CameraInvProjection, float4(IN.uv.xy * 2 - 1, 0, -1));
				OUT.viewVector = mul(unity_CameraToWorld, float4(viewVector,0));
                OUT.worldPos =  mul (unity_ObjectToWorld, IN.uv);
            	
                return OUT;
            }
            float3 sunDir;
            // float planetSize = 3;
			// Calculate densities $\rho$.
			// Returns vec2(rho_rayleigh, rho_mie)
			// Note that intro version is more complicated and adds clouds by abusing Mie scattering density. That's why it's a separate function
			float2 densitiesRM(float3 p)
            {
				float h = max(0., length(p - _PlanetLocation) - atmosphereScale); // calculate height from Earth surface
				// float height01 = (h / ( atmosphereScale - _PlanetSize) );
				return float2(exp(-h/8e3), exp(-h/12e2));
			}

            
			float NormalizedHeighValue(float3 samplePos)
            {
            	// if(samplePos.y > _AtmosphereHeight)
            	// {
            	// 	return 0;
            	// }
	            return (1-(samplePos.y) / (_AtmosphereHeight));
            }

            half ShadowAtten(float3 worldPosition)
			{
			        return MainLightRealtimeShadow(TransformWorldToShadowCoord(worldPosition));
			}


            half ShadowAtten2(float3 worldPosition)
			{
				half cascadeIndex = ComputeCascadeIndex(worldPosition);
				float4 coords = mul(_MainLightWorldToShadow[cascadeIndex], float4(worldPosition, 1.0));
				                           
				ShadowSamplingData shadowSamplingData = GetMainLightShadowSamplingData();
				half4 shadowParams = GetMainLightShadowParams();
				float atten = SampleShadowmap(TEXTURE2D_ARGS(_MainLightShadowmapTexture, sampler_MainLightShadowmapTexture), coords, shadowSamplingData, shadowParams, false);
				return  shadowParams.r + atten * (1 - shadowParams.r);
			}
            
			// float sunDepth(float3 rayOrigin, float3 sunDir, float dotToLight)
	  //       {
	  //           
			// 	// float height = max(0., length(rayOrigin - float3(0,- planetSize, 0)) - planetSize); // calculate height from Earth surface
			// 	// return float(exp(-height/8e3));
			// 	// return float(exp(-height/8e3), exp(-h/12e2));
	  //   
	  //           float3 densitySamplePoint = rayOrigin;
	  //           float rayLength = (1-dotToLight);
	  //           // float rayLength = 100 * _AtmosphereHeight;
	  //           float stepSize = rayLength / (_OpticalDepthPoints - 1);
	  //
	  //           float opticalDepth = 0;
	  //           for (int i = 0; i < _OpticalDepthPoints; i ++)
			// 	{	            	
			// 		// float localDensity = densitiesRM(densitySamplePoint).x;
			// 		float localDensity = NormalizedHeighValue(densitySamplePoint);
			// 		// opticalDepth += localDensity / (_OpticalDepthPoints);
		 //            opticalDepth += localDensity  * stepSize;
	  //
			// 		densitySamplePoint += sunDir * stepSize;
			// 	}
	  //           
	  //           return opticalDepth;
	  //       }

            static const float maxFloat = 3.402823466e+38;
            float2 raySphere(float3 sphereCentre, float sphereRadius, float3 rayOrigin, float3 rayDir)
            {
				// float3 offset = rayOrigin - sphereCentre;
				float3 offset = rayOrigin - sphereCentre;
				float a = 1; // Set to dot(rayDir, rayDir) if rayDir might not be normalized
				float b = 2 * dot(offset, rayDir);
				float c = dot (offset, offset) - sphereRadius * sphereRadius;
				float d = b * b - 4 * a * c; // Discriminant from quadratic formula
 
				// Number of intersections: 0 when d < 0; 1 when d = 0; 2 when d > 0
				if (d > 0) {
					float s = sqrt(d);
					float dstToSphereNear = max(0, (-b - s) / (2 * a));
					float dstToSphereFar = (-b + s) / (2 * a);

					// Ignore intersections that occur behind the ray
					if (dstToSphereFar >= 0) {
						return float2(dstToSphereNear, dstToSphereFar - dstToSphereNear);
					}
				}
				// Ray did not intersect sphere
				return float2(maxFloat, 0);
			}
            
             float densityAtPoint(float3 samplePoint)
            {
            	// return densitiesRM(samplePoint).x;
            	float heightAboveSurface = length(samplePoint - _PlanetLocation ) - _PlanetSize;
            	// float height01 = heightAboveSurface / (_AtmosphereHeight - _PlanetSize);
            	float height01 = (heightAboveSurface / ( atmosphereScale - _PlanetSize) );
            	// float localDensity = exp(-height01 * _DensityFalloff) * (1-height01);
            	float localDensity = exp(-height01 * _DensityFalloff) * (1 -height01);
            	
            	return localDensity;
            }

            
  //           float optic( float3 origin, float3 rayDir, float rayLength )
  //           {
		// 	float3 s = ( rayDir - origin ) / float( _OpticalDepthPoints );
		// 	float3 v = origin + s * 0.5;
		// 	
		// 	float sum = 0.0;
		// 	for ( int i = 0; i < _OpticalDepthPoints; i++ ) {
		// 		sum += densityAtPoint( v);
		// 		v += s;
		// 	}
		// 	sum *= length( s );
		// 	
		// 	return sum;
		// }
            float opticalDepth(float3 rayOrigin, float3 rayDir, float rayLength)
            {
				float3 densitySamplePoint = rayOrigin;
				float stepSize = rayLength / (_OpticalDepthPoints - 1);
				float opticalDepth = 0;
				float sunDot = clamp(dot(rayDir, sunDir), 0.0, 1.0);
    			float sunDotSmall = pow( sunDot, 350.0 ) * stepSize;

				for (int i = 0; i < _OpticalDepthPoints; i ++)
				{
            		
					// float localDensity = densityAtPoint(densitySamplePoint);
					float localDensity = densityAtPoint(densitySamplePoint) ;
					// float mie = densitiesRM(densitySamplePoint).x * rayLength;
					// localDensity += mie;
					// opticalDepth += -sunDotSmall;
					// float localDensity = densitiesRM(densitySamplePoint).y;
					opticalDepth += localDensity * stepSize;
					// opticalDepth += localDensity / _OpticalDepthPoints;
					densitySamplePoint += rayDir * stepSize;
				}
				return opticalDepth;
			}

            // float G_SCATTERING = 0;
			float ComputeScattering(float lightDotView)
			{
				float result = 1.0f - _SunLightScattering * _SunLightScattering;				
				result /= 4.0f * PI * pow(1.0f + _SunLightScattering * _SunLightScattering - (2.0f * _SunLightScattering) * lightDotView, 1.5f);
				// result /= 100.0f * PI * pow(1 + _SunLightScattering * _SunLightScattering - (2.0f * _SunLightScattering) * lightDotView, 1.5);
				return result; 				
			}
            
			const float3 bR = float3(58, 135, 331); // Rayleigh scattering coefficient
			// const float3 bR = float3(58e-7, 135e-7, 331e-7); // Rayleigh scattering coefficient
			const float3 bMs = float3(2e-5, 2e-5, 2e-5); // Mie scattering coefficients
			// const float3 bMe = bMs * 1.1;
            // float4 scatteringCoefficients;

            float3 _betaR = float3(1.95e-2, 1.1e-1, 2.94e-1); 
			float3 _betaM = float3(4e-2, 4e-2, 4e-2);

			float3 calcLightTest(float3 rayOrigin, float3 rayDir, float length, float3 originalCol, float3 wPos, float dist)
            {

            	float rayLength = length;
            	float rayDirLengthened = rayDir * length;
            	
            	float3 inScatterPoint = rayOrigin;
            	float stepSize = rayLength / (_ScatteringPoints -1);
            	float3 lightDirection = normalize(_MainLightPosition.xyz);
            	float Ldot = dot(normalize(rayDir), lightDirection);
            	float4 color = 0;
            	// float4 color = Ldot;
            	float3 inScatteredLight = 0;
            	float viewRayOpticalDepth = 0;         	
            	float rayOpticalDepth = 0;         	
            	float sunDot = clamp(dot(rayDir, sunDir), 0.0, 1.0);
    			float sunDotSmall = pow( sunDot, 700.0 );
    			float sunDotlarge = (pow( sunDot, 2.0 ));
				float3 inScatterPoint2 = _WorldSpaceCameraPos;
				float3 I_R = 0;
				float3 I_M = 0;
				for(int i = 0; i < _ScatteringPoints; i++)
            	{
					float3 localSunDir = normalize(rayDir - sunDir);
					float sunRayLength = raySphere(_PlanetLocation, atmosphereScale, inScatterPoint, sunDir).y;
					// float sunRayLength = raySphere(0, _AtmosphereHeight, inScatterPoint, localSunDir).y;
					rayOpticalDepth = opticalDepth(inScatterPoint, sunDir, sunRayLength);
					viewRayOpticalDepth = opticalDepth(inScatterPoint, -rayDir, stepSize * i);
					// float localDensity = densityAtPoint(inScatterPoint);
					float localDensity = densityAtPoint(inScatterPoint);
					// float localDensity = densitiesRM(inScatterPoint).y;
					// localDensity += mie;
					// float localDensity = densitiesRM(inScatterPoint) * length;
					// float transmittance = exp(-(rayOpticalDepth));
					// float3 expo = exp(-bR * localDensity.x);

					
					float3 transmittance = exp(-( rayOpticalDepth + viewRayOpticalDepth) * scatteringCoefficients);
					// float3 expo = exp(-bR * localDensity.x - bMe * totalDepthRM.y)
					// float localDensity = densityAtPoint(inScatterPoint);
					
					// float3 dirToLight = inScatterPoint - lightDirection;
					// float t = dot(Ldot, normalize(dirToLight));
					// inScatteredLight += localDensity;
					
					// if((inScatterPoint - _WorldSpaceCameraPos).y  > 10)
					// {
					// 	return 0;
					// }
					inScatteredLight += localDensity * transmittance;
					// inScatteredLight += transmittance;
					// inScatteredLight += localDensity;
					// inScatteredLight += localDensity * transmittance;
					
					// inScatteredLight +=  transmittance;
					// inScatteredLight += 1000 * stepSize;
					// inScatteredLight += stepSize;

					inScatterPoint += rayDir * stepSize;
					
					// I_R += A * dRM.x;
					// I_M += A * dRM.y;
					// float atmos = saturate(NormalizedHeighValue(inScatterPoint)/ _ScatteringPoints) ;
					// float depth = (-exp((sunDepth(inScatterPoint, dirToLight, t)) / _ScatteringPoints) );
					// float depth2 = (-exp((sunDepth(inScatterPoint, -rayDir, t)) / _ScatteringPoints) );
					// inScatteredLight += depth * depth2;
			
				}
				
				// return inScatteredLight * 1260.2;
				// mu = cos(alpha)
				float mu = dot(rayDir, sunDir);
				// const float brightnessAdaptionStrength = 0.15;
				// const float reflectedLightOutScatterStrength = 3;
				// float brightnessAdaption = dot (inScatteredLight,1) * brightnessAdaptionStrength;
				// float brightnessSum = viewRayOpticalDepth * 1 * reflectedLightOutScatterStrength + brightnessAdaption;
				// float reflectedLightStrength = exp(-brightnessSum);
				// float hdrStrength = saturate(dot(originalCol,1)/3-1);
				// reflectedLightStrength = lerp(reflectedLightStrength, 1, hdrStrength);
				// float3 reflectedLight = originalCol * reflectedLightStrength;
				//
				// float3 finalCol = reflectedLight + inScatteredLight;
				// return finalCol;
				// inScatteredLight += sunDotSmall;
				float3 bR = float3(58e-7, 135e-7, 331e-7);
				float3 bMs = float3(58e-7, 135e-7, 331e-7) * 1.1;
				// (inScatteredLight * bR * .0597 +
				// inScatteredLight * bMs * .0196 / pow(1.58 - 1.52 * mu, 1.5));
				// inScatteredLight *= scatteringCoefficients  * stepSize;
				float originalSunRayOpticalDepth = exp(-rayOpticalDepth);
				float originalColTransmittance = exp(-viewRayOpticalDepth);
				// return originalColTransmittance;
				// float sunPow = saturate(saturate(exp(sunDotSmall)) + sunDotlarge * sunDotlarge) * (originalSunRayOpticalDepth * .0597 +
				// originalSunRayOpticalDepth * .0196 / pow(1.58 - 1.52 * sunDotlarge , 1.5)) ;

				float sunPow = 0;
				// return sunPow;
				// float sunPower = saturate(saturate(exp(sunDotSmall)) + sunDotlarge * sunDotlarge) * (originalSunRayOpticalDepth * .0597 +
				// originalSunRayOpticalDepth * .0196 / pow(1.58 - 1.52 * sunDotlarge, 1.5)) ;
				// sunPow *= saturate(originalColTransmittance);
				// return sunPow;
				// return length;
				float distTravelled = 0;
				
				float stepSize2 = 1;
				int steps = 1000;
				while(distTravelled < steps )
                {
                	// distTravelled += ;
                    float3 rayPos = wPos + rayDir * distTravelled ;
                	// float4 worldInShadowCameraSpace = mul(float4(rayPos, 1.0f), g_ShadowViewProjectionMatrix);
				// worldInShadowCameraSpace /= worldInShadowCameraSpace.w;
                    // if(ShadowAtten(rayPos) < 0.01 &&  distTravelled < dist) 
                    if(ShadowAtten(rayPos) > 0.01 &&  distTravelled < dist) 
                    {
      //               	float sunPower = saturate(saturate(exp(sunDotSmall)) + sunDotlarge * sunDotlarge) * (originalSunRayOpticalDepth * .0597 +
						// originalSunRayOpticalDepth * .0196 / pow(1.58 - 1.52 * sunDotlarge , 1.5)) ;
                       // sunPow *= 0.1 * stepSize2;
                    	// sunPow += sunPower / steps;
                    	sunPow += (ComputeScattering(dot(rayDir, sunDir)));
						// sunPow += sunPower / 1000;
                    	
						//todo:
                    	//mutlply with 1-dot(up vector, sundir)
                    	//multoply with depth or viewrayopticaldepth? fade out same rate as atmosphere applies
                    	
                    	// sunPow /= 1000;
                    	// sunPow = saturate(sunPow);
                    	// 
                    	// sunPow += ComputeScattering(dot(rayDir, sunDir));
                    }
					// sunPow += 0.1;
					
				 	if(ShadowAtten(rayPos) < 0.01 &&  distTravelled < dist)
				 	{
				 		sunPow -= (ComputeScattering(dot(rayDir, sunDir))) * _VolumetricShadowPower;
				 	}
                    distTravelled += stepSize2;
                    
                }
				sunPow/= steps;
				// return sunPow;
				sunPow = clamp(sunPow, 0, 99);
				// return sunPow;
				// sunPow -= (1-viewRayOpticalDepth);
				// return sunPow ;
				inScatteredLight *=  (scatteringCoefficients + sunPow ) * stepSize;
				// return inScatteredLight * (scatteringCoefficients * stepSize);
				// return pow( originalTayOpticalDepth, 2 );
				// inScatteredLight *= scatteringCoefficients * stepSize;
            	return originalCol  * originalColTransmittance  + inScatteredLight ;
            	// return originalColTransmittance ;
            	
            }

            
			// Basically a ray-sphere intersection. Find distance to where rays escapes a sphere with given radius.
			// Used to calculate length at which ray escapes atmosphere
			float escape(float3 p, float3 d, float R)
            {
				float3 v = p - float3(0, 0, 0);
				float b = dot(v, d);
				float det = b * b - dot(v, v) + R*R;
				if (det < 0.) return -1.;
				det = sqrt(det);
				float t1 = -b - det, t2 = -b + det;
				return (t1 >= 0.) ? t1 : t2;
			}
             float Dither17(float2 Pos, float FrameIndexMod4)
		      {
		          // 3 scalar float ALU (1 mul, 2 mad, 1 frac)
		          return frac(dot(float3(Pos.xy, FrameIndexMod4), uint3(2, 7, 23) / 17.0f));
		      }	
            half4 frag(Varyings IN) : SV_Target
            {
            	// sunDir = float3(0,0,1);
            	// return ShadowAtten(IN.positionWS);
            	sunDir = normalize(_MainLightPosition.xyz);   
                // float nonLinearDepth =  SAMPLE_TEXTURE2D(_CameraDepthTexture, sampler_CameraDepthTexture, IN.uv.xy).r * length(IN.viewVector);
                float nonLinearDepth =  SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, IN.uv.xy).r;
				// #if UNITY_REVERSED_Z
				//             nonLinearDepth = 1 - nonLinearDepth;
				// #endif
				//             nonLinearDepth = 2 * nonLinearDepth - 1; //NOTE: Currently must massage depth before computing CS position.
				// return nonLinearDepth*5;
				float3 vpos = ComputeViewSpacePosition(IN.uv.zw, nonLinearDepth, unity_CameraInvProjection);
            	float3 wpos = mul(unity_CameraToWorld, float4(vpos, 1)).xyz;
            	// float3 wpos = IN.worldPos;
            	 // float cameraDistance = cameraDepth / normalize(viewSpacePos.xyz).z;
            	 // float cameraDepth = LinearEyeDepth(tex2D(_CameraDepthTexture, screenPos / _ScreenParams.xy));

            	float3 viewDir = wpos-_WorldSpaceCameraPos;
				float distance = length(IN.viewVector);
            	// return distance;
            	float dist2 = LinearEyeDepth(nonLinearDepth, _ZBufferParams) * distance;
            	float dist3 = LinearEyeDepth(nonLinearDepth, _ZBufferParams);
            	// return dist2 / 10;
            	// return (distance) / 10;
            	// return distance;
            	float sceneDepth = LinearEyeDepth(nonLinearDepth, _ZBufferParams) * distance / (_DepthDistance / (_PlanetSize));
            	// float sceneDepth = LinearEyeDepth(nonLinearDepth, _ZBufferParams);// * distance / (_DepthDistance / (_PlanetSize));
            	// float sceneDepth = LinearEyeDepth(nonLinearDepth, _ZBufferParams) * distance / _DepthDistance;
            	// float sceneDepth = LinearEyeDepth(nonLinearDepth, _ZBufferParams) * distance / _DepthDistance;
				// nonLinearDepth = saturate(nonLinearDepth);
            	// return sceneDepth*0.01;
                float3 origin = _WorldSpaceCameraPos;
            	// float3 rayDir = (IN.viewVector);
            	float3 rayDir = normalize(IN.viewVector);

				
            	// return float4(normalize(viewDir), 1);
            	// atmosphereScale = (1 + _AtmosphereHeight) * _PlanetSize;
            	atmosphereScale = (1 + _AtmosphereHeight) * _PlanetSize;
            	float2 hitSphere = raySphere(_PlanetLocation, atmosphereScale, origin, (rayDir));
            	// return sceneDepth;
            	float esc = escape(origin, rayDir, atmosphereScale);
            	// return esc;
            	float distToAtmosphere = hitSphere.x;
            	float d = min(sceneDepth - distToAtmosphere, hitSphere.y);
            	// float distTthroughAtmosphere =  saturate(1-(hitSphere.x /  d));
            	// float distTthroughAtmosphere =  d / (_AtmosphereHeight * 2);
            	float distTthroughAtmosphere =  min(hitSphere.y, sceneDepth - distToAtmosphere);
            	// return d;
            	// float distTthroughAtmosphere =  min(hitSphere.y, sceneDepth - distToAtmosphere);
            	// distTthroughAtmosphere = distTthroughAtmosphere / (atmosphereScale * 2);
            	float4 col = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, IN.uv);

				float sunDot = clamp(dot(rayDir, sunDir), 0.0, 1.0);
    			// float sunDotSmall = pow( sunDot, 350.0 );
            	// float l = distTthroughAtmosphere / (_ScatteringPoints -1);
            	// col.rgb += (0.47*float3(1.6,1.4,1.0)*pow( sunDot, 350.0 ));
            	// col.rgb += 0.4*float3(0.8,0.9,1.0)*pow( sunDot, 20.0 );
            	// return d ;
            	// return distTthroughAtmosphere / (atmosphereScale * 2) * float4(rayDir.rgb * 0.5 + 0.5, 0.5);
            	// return distTthroughAtmosphere / (atmosphereScale * 2);
            	// return col;ff
            	
            	// float stepSize = distTthroughAtmosphere / 10;
            	float stepSize = 0.1;
                float distTravelled = 0;
            	// float rayLength = length(rayVector);
                float stepLength = 15 / _ScatteringPoints;
            	// float3 step = rayDir * stepLength;
				float3 camVec = normalize( mul(_WorldSpaceCameraPos, unity_WorldToObject) );
				float3 currentPosition = wpos;
            	float3 col2 = col.rgb;
            	
    //         	[loop]
            	// for (int i = 0; i < 500; i++)
    //         	int i = 0;
    //         	while(i < 1500)
				// {
    //         		i++;
    //         		 float3 rayPos = wpos + rayDir * distTravelled;
				// 	if(ShadowAtten(rayPos) < 0.1  && distTravelled < dist2-0.1)
				// 	{
				// 		col2 += 0.1;
				// 	}
				// 	currentPosition += -camVec * stepLength;
    //         		distTravelled += stepSize;
    //         	}
					float4x4 ditherPattern = {{ 0.0f, 0.5f, 0.125f, 0.625f},
					{ 0.75f, 0.22f, 0.875f, 0.375f},
					{ 0.1875f, 0.6875f, 0.0625f, 0.5625},
					{ 0.9375f, 0.4375f, 0.8125f, 0.3125}};	
				// float3 step = rayDir * stepLength;
            	// return dist3 / (_DepthDistance) ;
                // while(distTravelled < 100 )
                // {
                // 	// distTravelled += ;
                //     float3 rayPos = wpos + rayDir * distTravelled ;
                // 	
                //     if(ShadowAtten(rayPos) < 0.1 && distTravelled < dist2) 
                //     {
                //         col2 += 0.1;
                //     }
                //     distTravelled += stepSize;
                //     
                // }
            	
    			// return float4(col2.rgb, 1);
    //         	
            	if(distTthroughAtmosphere > 0)
            	{
            		const float epsilon = 0.0001;
            		float3 pointInAtmosphere = origin + rayDir * (distToAtmosphere + epsilon);  
            		float3 light = calcLightTest(pointInAtmosphere, rayDir, distTthroughAtmosphere - epsilon * 2, col.rgb, origin, dist2);
            		// return float4(pointInAtmosphere, 1);
            		return float4(light, 1);
            		// return col * (1- light) + light;
            		// return (1-light) + light;
            		// return saturate(1-light) + light;
            	}
            	return col;
				// float esc = escape(origin, rayDir, planetSize);
            	// return esc;
				// return (calcLightTest(origin, rayDir, esc));
            	return min(col, sceneDepth);
            }
            ENDHLSL
        }
    	// Used for rendering shadowmaps
    }
}