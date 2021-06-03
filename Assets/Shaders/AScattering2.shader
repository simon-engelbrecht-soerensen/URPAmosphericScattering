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
                
                return OUT;
            }
            float3 sunDir;
            // float planetSize = 3;
			// Calculate densities $\rho$.
			// Returns vec2(rho_rayleigh, rho_mie)
			// Note that intro version is more complicated and adds clouds by abusing Mie scattering density. That's why it's a separate function
			float2 densitiesRM(float3 p)
            {
				float h = max(0., length(p - _PlanetLocation) - _PlanetSize); // calculate height from Earth surface
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
            
			float sunDepth(float3 rayOrigin, float3 sunDir, float dotToLight)
	        {
	            
				// float height = max(0., length(rayOrigin - float3(0,- planetSize, 0)) - planetSize); // calculate height from Earth surface
				// return float(exp(-height/8e3));
				// return float(exp(-height/8e3), exp(-h/12e2));
	    
	            float3 densitySamplePoint = rayOrigin;
	            float rayLength = (1-dotToLight);
	            // float rayLength = 100 * _AtmosphereHeight;
	            float stepSize = rayLength / (_OpticalDepthPoints - 1);

	            float opticalDepth = 0;
	            for (int i = 0; i < _OpticalDepthPoints; i ++)
				{	            	
					// float localDensity = densitiesRM(densitySamplePoint).x;
					float localDensity = NormalizedHeighValue(densitySamplePoint);
					// opticalDepth += localDensity / (_OpticalDepthPoints);
		            opticalDepth += localDensity  * stepSize;

					densitySamplePoint += sunDir * stepSize;
				}
	            
	            return opticalDepth;
	        }

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
            	float heightAboveSurface = length(samplePoint - (_PlanetLocation )) - _PlanetSize;
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

				for (int i = 0; i < _OpticalDepthPoints; i ++)
				{
					// float localDensity = densityAtPoint(densitySamplePoint);
					float localDensity = densityAtPoint(densitySamplePoint);
					// float localDensity = densitiesRM(densitySamplePoint).y;
					opticalDepth += localDensity * stepSize;
					// opticalDepth += localDensity / _OpticalDepthPoints;
					densitySamplePoint += rayDir * stepSize;
				}
				return opticalDepth;
			}


			const float3 bR = float3(58, 135, 331); // Rayleigh scattering coefficient
			// const float3 bR = float3(58e-7, 135e-7, 331e-7); // Rayleigh scattering coefficient
			const float3 bMs = float3(2e-5, 2e-5, 2e-5); // Mie scattering coefficients
			// const float3 bMe = bMs * 1.1;
            // float4 scatteringCoefficients;
			float3 calcLightTest(float3 rayOrigin, float3 rayDir, float length, float3 originalCol)
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
            	
				for(int i = 0; i < _ScatteringPoints; i++)
            	{
					float3 localSunDir = normalize(rayDir - sunDir);
					float sunRayLength = raySphere(_PlanetLocation, atmosphereScale, inScatterPoint, sunDir).y;
					// float sunRayLength = raySphere(0, _AtmosphereHeight, inScatterPoint, localSunDir).y;
					float rayOpticalDepth = opticalDepth(inScatterPoint, sunDir, sunRayLength);
					viewRayOpticalDepth = opticalDepth(inScatterPoint, -rayDir, stepSize * i);
					float localDensity = densityAtPoint(inScatterPoint);
					// float localDensity = densitiesRM(inScatterPoint) * length;
					// float transmittance = exp(-(rayOpticalDepth));
					// float3 expo = exp(-bR * localDensity.x);
					float3 transmittance = exp(-(rayOpticalDepth + viewRayOpticalDepth) * scatteringCoefficients);
					// float3 expo = exp(-bR * localDensity.x - bMe * totalDepthRM.y)
					// float localDensity = densityAtPoint(inScatterPoint);
					
					// float3 dirToLight = inScatterPoint - lightDirection;
					// float t = dot(Ldot, normalize(dirToLight));
					// inScatteredLight += localDensity;
					inScatteredLight += localDensity * transmittance;
					
					// inScatteredLight +=  transmittance;
					// inScatteredLight += 1000 * stepSize;
					// inScatteredLight += stepSize;

					inScatterPoint += rayDir * stepSize;

					// float atmos = saturate(NormalizedHeighValue(inScatterPoint)/ _ScatteringPoints) ;
					// float depth = (-exp((sunDepth(inScatterPoint, dirToLight, t)) / _ScatteringPoints) );
					// float depth2 = (-exp((sunDepth(inScatterPoint, -rayDir, t)) / _ScatteringPoints) );
					// inScatteredLight += depth * depth2;
			
				}
				float originalColTransmittance = exp(-viewRayOpticalDepth);
				inScatteredLight *= scatteringCoefficients * stepSize;
            	return originalCol * originalColTransmittance + inScatteredLight ;
            	
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
            
            half4 frag(Varyings IN) : SV_Target
            {
            	// sunDir = float3(0,0,1);   
            	sunDir = normalize(_MainLightPosition.xyz);   
                // float nonLinearDepth =  SAMPLE_TEXTURE2D(_CameraDepthTexture, sampler_CameraDepthTexture, IN.uv.xy).r * length(IN.viewVector);
                float nonLinearDepth =  SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, IN.uv.xy).r;
				// #if UNITY_REVERSED_Z
				//             nonLinearDepth = 1 - nonLinearDepth;
				// #endif
				//             nonLinearDepth = 2 * nonLinearDepth - 1; //NOTE: Currently must massage depth before computing CS position.

				float3 vpos = ComputeViewSpacePosition(IN.uv.zw, nonLinearDepth, unity_CameraInvProjection);
            	float3 wpos = mul(unity_CameraToWorld, float4(vpos, 1)).xyz;
            	float3 viewDir = wpos-_WorldSpaceCameraPos;
				float distance = length(IN.viewVector);
            	// return distance;
            	float sceneDepth = LinearEyeDepth(nonLinearDepth, _ZBufferParams) * distance / _DepthDistance;
            	// float sceneDepth = LinearEyeDepth(nonLinearDepth, _ZBufferParams) * distance / _DepthDistance;
				// nonLinearDepth = saturate(nonLinearDepth);
            	// return sceneDepth;
                float3 origin = _WorldSpaceCameraPos;
            	// float3 rayDir = (IN.viewVector);
            	float3 rayDir = normalize(IN.viewVector);

            	// return float4(normalize(viewDir), 1);
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
            	// float distTthroughAtmosphere =  min(hitSphere.y, sceneDepth - distToAtmosphere);
            	// distTthroughAtmosphere = distTthroughAtmosphere / (atmosphereScale * 2);
            	float4 col = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, IN.uv);

            	// return d ;
            	// return distTthroughAtmosphere / (atmosphereScale * 2) * float4(rayDir.rgb * 0.5 + 0.5, 0.5);
            	// return col;ff
            	if(distTthroughAtmosphere > 0)
            	{
            		const float epsilon = 0.0001;
            		float3 pointInAtmosphere = origin + rayDir * (distToAtmosphere + epsilon);  
            		float3 light = calcLightTest(pointInAtmosphere, rayDir, distTthroughAtmosphere - epsilon * 2, col.rgb);
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