Shader "Universal Render Pipeline/Custom/AScattering"
{
    Properties
    {
        [MainColor] _BaseColor("BaseColor", Color) = (1,1,1,1)
        [MainTexture] _MainTex("Main Tex", 2D) = "white" {}
    	_ScatteringPoints("ScatteringPoints", int) = 10
    	_OpticalDepthPoints("Optical Depth Points", int) = 10
    	_DensityFalloff("Density Falloff", float) = 10
    	_AtmosphereHeight("Atmosphere Height", float) = 3
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
            int _DensityFalloff;
            float _AtmosphereHeight;
            float _DepthDistance;


            // scattering coefficients at sea level (m)
			const float3 betaR = float3(5.5e-6, 13.0e-6, 22.4e-6); // Rayleigh 
			const float3 betaM = float3(21e-6, 21e-6, 21e-6); // Mie

			// scale height (m)
			// thickness of the atmosphere if its density were uniform
			const float hR = 7994.0; // Rayleigh
			const float hM = 1200.0; // Mie

			struct RayT
            {
			    float3 origin;
			    float3 direction;
			};
            
			struct sphere
            {
			    float3 origin;
			    float radius;
			};
            
			float rayleigh_phase_func(float mu){
			    return 3.*(1.+mu*mu)/(16.*PI);
			}

			//A beloved classic
			const float g = 0.76;
			float henyey_greenstein_phase_func(float mu)
			{
				return
									(1. - g*g)
				/ //---------------------------------------------
					((4. * PI) * pow(1. + g*g - 2.*g*mu, 1.5));
			}


            
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

            const float R0 = 6360e3; // Earth surface radius
			const float Ra = 6380e3; // Earth atmosphere top raduis
			const float3 bR = float3(58e-7, 135e-7, 331e-7); // Rayleigh scattering coefficient
			const float3 bMs = float3(2e-5, 2e-5, 2e-5); // Mie scattering coefficients
			// const float3 bMe = bMs * 1.1;
			const float I = 10.; // Sun intensity
			float3 sunDir;
			// const float3 C = float3(0., -R0, 0.); // Earth center point
			// 
			// Basically a ray-sphere intersection. Find distance to where rays escapes a sphere with given radius.
			// Used to calculate length at which ray escapes atmosphere
			float escape(float3 p, float3 d, float R)
            {
				float3 C = float3(0., -R0, 0.);
				
				float3 v = p - C;
				float b = dot(v, d);
				float det = b * b - dot(v, v) + R*R;
				if (det < 0.) return -1.;
				det = sqrt(det);
				float t1 = -b - det, t2 = -b + det;
				return (t1 >= 0.) ? t1 : t2;
			}
            
            static const float maxFloat = 3.402823466e+38;
            float2 raySphere(float3 sphereCentre, float sphereRadius, float3 rayOrigin, float3 rayDir)
            {
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
            
            float intersectPlane(float3 rayDir) 
			{ 
			    // assuming vectors are all normalized
            	float3 planeNormal = float3(0,-1,0); //just up
            	// worldOrigin = 0;
			    float denom = dot(planeNormal, rayDir);

            	// if(denom > 0)
            	// {
            	// 	return 0;
            	// }
            	return distance(rayDir.y, 0) * _AtmosphereHeight; //height
            	
			    // if (denom > 1e-6) { 
			    //     float3 p0l0 = rayOrigin; 
			    //     float t = dot(p0l0, planeNormal) / denom;
			    // 	return denom * 1;
			    // 	if(t >= 0)
			    // 	{
			    // 		return t;			    		
			    // 	}
			    //     // return (t >= 0); 
			    // } 
			    //
			    // return 0; 
			}
            
			float NormalizedHeighValue(float3 samplePos)
            {
            	// if(samplePos.y > _AtmosphereHeight)
            	// {
            	// 	return 0;
            	// }
	            return (1-(samplePos.y) / (_AtmosphereHeight));
            }
            
            float densityAtPoint(float3 samplePoint)
            {
	            float heightAboveSurface = distance(samplePoint.y, 0);
            	float height01 = heightAboveSurface / _AtmosphereHeight;
            	float localDensity = exp(-height01 * _DensityFalloff) * (1-height01);
            	return localDensity;
            }

           float opticalDepth(float3 rayOrigin, float3 rayDir, float rayLength)
            {
				float3 densitySamplePoint = rayOrigin;
				float stepSize = rayLength / (_OpticalDepthPoints - 1);
				float opticalDepth = 0;

				for (int i = 0; i < _OpticalDepthPoints; i ++)
				{
					float localDensity = NormalizedHeighValue(densitySamplePoint);
					// opticalDepth += localDensity * stepSize;
					opticalDepth += localDensity / _OpticalDepthPoints;
					densitySamplePoint += rayDir * stepSize;
				}
				return opticalDepth;
			}

            float sunRayLength(float3 origin, float3 sunDir)
            {
            	float distToHeight = distance(origin.y, 0) * _AtmosphereHeight;
	            // return distance(origin, sun);
            }
            
			
            
            float sunDepth(float3 rayOrigin, float3 sunDir, float dotToLight)
            {

            	float3 densitySamplePoint = rayOrigin;
            	float rayLength = (1-dotToLight);
            	// float rayLength = 100 * _AtmosphereHeight;
            	float stepSize = rayLength / (_OpticalDepthPoints - 1);

            	float opticalDepth = 0;
	            for (int i = 0; i < _OpticalDepthPoints; i ++)
				{	            	
					float localDensity = NormalizedHeighValue(densitySamplePoint);
					// opticalDepth += localDensity / (_OpticalDepthPoints);
	            	opticalDepth += localDensity  * stepSize;

					densitySamplePoint += sunDir * stepSize;
				}
            	
            	return opticalDepth;
            }
            

            float4 calcLightTest(float3 rayOrigin, float3 rayDir)
            {
            	int rayLength = 1000;
            	float3 inScatterPoint = rayOrigin;
            	float stepSize = rayLength / (_ScatteringPoints -1);
            	float3 lightDirection = normalize(_MainLightPosition.xyz);
            	float Ldot = dot(normalize(rayDir), lightDirection);
            	float4 color = 0;
            	// float4 color = Ldot;
            	float inScatteredLight = 0;
            	

            	
            	
				for(int i = 0; i < _ScatteringPoints; i++)
            	{					
					inScatterPoint += rayDir * stepSize;
					float3 dirToLight = inScatterPoint - lightDirection;
					float t = dot(Ldot, normalize(dirToLight));

					// float atmos = saturate(NormalizedHeighValue(inScatterPoint)/ _ScatteringPoints) ;
					float depth = (-exp((sunDepth(inScatterPoint, dirToLight, t)) / _ScatteringPoints) );
					float depth2 = (-exp((sunDepth(inScatterPoint, -rayDir, t)) / _ScatteringPoints) );
					inScatteredLight += depth * depth2;
					// inScatteredLight += opticalDepth(inScatterPoint, dirToLight, 100) / _ScatteringPoints;
					// if(t < 0)
					// {
					// 	continue;
					// }
					// color += t * -stepSize / 1000;
					//
					//
					// color += NormalizedHeighValue(inScatterPoint)/ _ScatteringPoints;
					// color += (1-(inScatterPoint.y) / (_AtmosphereHeight)) / _ScatteringPoints;
					//
					// if((t) < 0.9)
					// {
					// 	continue;
					// }
					 // color += t / _ScatteringPoints;
					//
					//
					// color += (sunDepth(inScatterPoint, dirToLight) / _ScatteringPoints);
					// color += NormalizedHeighValue(inScatterPoint) / _ScatteringPoints;
					// if(t > 0.9)
					// {
					// 	color *= float4(0,1,0,0);
					// }
					// if(inScatterPoint.y < 3)
					// {
						// return inScatterPoint;
						// return densityAtPoint(inScatterPoint);
						// float4(dirToLight, 0);
						// return color;
						// return sin(distance(inScatterPoint, rayOrigin) /_ScatteringPoints);
					// }
				}
            	return inScatteredLight;
            	
            }
            float calcLight(float3 rayOrigin, float3 rayDir, float rayLength)
            {
				float3 inScatterPoint = rayOrigin;
            	float stepSize = rayLength / (_ScatteringPoints -1);
            	float inScatteredLight = 0;
            	
            	float3 lightDirection = normalize(_MainLightPosition.xyz);
            	for(int i = 0; i < _ScatteringPoints; i++)
            	{

            		// float raylength
            		//get density along ray towards sun from current scatterpoint
            		float sunRayDepth = opticalDepth(inScatterPoint, lightDirection, rayLength);
            		float viewRayOpticalDepth = opticalDepth(inScatterPoint, -rayDir, stepSize * i);
            		//
            		// float sunRayLength = intersectPlane(3, inScatterPoint, lightDirection);
            		// float sunRayLength
            		float transmittance = exp(-(sunRayDepth + viewRayOpticalDepth));
            		float localDensity = densityAtPoint(inScatterPoint);
            		inScatteredLight += localDensity * transmittance * stepSize;
            		inScatteredLight += sunRayDepth;

            		
            		//iterate from camera and along ray
            		inScatterPoint += rayDir * stepSize;
            	}
            	return inScatteredLight;
            }

            // Calculate densities $\rho$.
			// Returns vec2(rho_rayleigh, rho_mie)
			// Note that intro version is more complicated and adds clouds by abusing Mie scattering density. That's why it's a separate function
			float2 densitiesRM(float3 p)
            {
            	float3 C = float3(0., -R0, 0.);
				float h = max(0., length(p - C) - R0); // calculate height from Earth surface
				return float2(exp(-h/8e3), exp(-h/12e2));
			}

            // Calculate density integral for optical depth for ray starting at point `p` in direction `d` for length `L`
			// Perform `steps` steps of integration
			// Returns vec2(depth_int_rayleigh, depth_int_mie)
			float2 scatterDepthInt(float3 origin, float3 dir, float length, float steps) {
				// Accumulator
				float2 depthRMs = float2(0,0);

				// Set L to be step distance and pre-multiply d with it
				length /= steps; dir *= length;
				
				// Go from point P to A
				for (float i = 0.; i < steps; ++i)
					// Simply accumulate densities
					depthRMs += densitiesRM(origin + dir * i);

				return depthRMs * length;
			}
            // Global variables, needed for size
			float2 totalDepthRM;
			float2 I_R, I_M;
			// Calculate in-scattering for ray starting at point `o` in direction `d` for length `L`
			// Perform `steps` steps of integration
			void scatterIn(float3 origin, float3 dir, float length, float steps)
            {
				float3 bMe = bMs * 1.1;
				// Set L to be step distance and pre-multiply d with it
				length /= steps; dir *= length;

				// Go from point O to B
				for (float i = 0.; i < steps; ++i)
				{
					// Calculate position of point P_i
					float3 p = origin + dir * i;

					// Calculate densities
					float2 dRM = densitiesRM(p) * length;

					// Accumulate T(P_i -> O) with the new P_i
					totalDepthRM += dRM;

					// Calculate sum of optical depths. totalDepthRM is T(P_i -> O)
					// scatterDepthInt calculates integral part for T(A -> P_i)
					// So depthRMSum becomes sum of both optical depths
					float2 depthRMsum = totalDepthRM + scatterDepthInt(p, sunDir, escape(p, sunDir, Ra), 4.);

					// Calculate e^(T(A -> P_i) + T(P_i -> O)
					float3 A = exp(-bR * depthRMsum.x - bMe * depthRMsum.y);

					// Accumulate I_R and I_M
					I_R += A * dRM.x;
					I_M += A * dRM.y;
				}
			}

            // Final scattering function
			// O = o -- starting point
			// B = o + d * L -- end point
			// Lo -- end point color to calculate extinction for
			float3 scatter(float3 origin, float3 dir, float length, float3 Lo)
            {
				float3 bMe = bMs * 1.1;
				// Zero T(P -> O) accumulator
				totalDepthRM = float2(0,0);

				// Zero I_M and I_R
				I_R = I_M = float3(0,0,0);

				// Compute T(P -> O) and I_M and I_R
				scatterIn(origin, dir, length, 16.);

				// mu = cos(alpha)
				float mu = dot(dir, sunDir);

				float2 t = exp(-bR * totalDepthRM.x - bMe * totalDepthRM.y)

				// Add in-scattering
					+ I * (1. + mu * mu) * (
						I_R * bR * .0597 +
						I_M * bMs * .0196 / pow(1.58 - 1.52 * mu, 1.5));
				// Calculate Lo extinction
				return float3(t.xy, t.x);// * exp(-bR * totalDepthRM.x - bMe * totalDepthRM.y)

				// Add in-scattering
					+ I * (1. + mu * mu) * (
						I_R * bR * .0597 +
						I_M * bMs * .0196 / pow(1.58 - 1.52 * mu, 1.5));
			}
            
            half4 frag(Varyings IN) : SV_Target
            {
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
				// nonLinearDepth = saturate(nonLinearDepth);
            	// return sceneDepth;
                float3 origin = _WorldSpaceCameraPos;
            	float3 rayDir = normalize(IN.viewVector);
				
				float2 hitInfo = raySphere(float3(0,0,0), 3.5, origin, rayDir);
            	float dstToAtmos = hitInfo.x;
            	float dstThough = min(hitInfo.y, sceneDepth - dstToAtmos);
            	float dstThough2 = hitInfo.y;
            	// float d = intersectPlane(3, origin, rayDir);
            	float d = densityAtPoint(rayDir);
            	// float d = opticalDepth(origin, rayDir, 10);
				float4 shadowCoord = TransformWorldToShadowCoord(IN.positionWS);
				Light mainLight = GetMainLight(shadowCoord);
            	float lightAmount = max( dot(normalize(mainLight.direction), -rayDir), 0);

            	float4 col = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, IN.uv);
					
            	sunDir = normalize(_MainLightPosition.xyz);
				float length = escape(origin, rayDir, Ra);
            	 
            	// return length;
            	// return dstThough;
            	// return float4(sqrt(scatter(origin, rayDir, length, col.xyz)), 1);
            	// return mainLight.shadowAttenuation;
            	// return min(1-d, sceneDepth);
            	// return (1-d) * nonLinearDepth;
            	// return min(depth, (1-d));
            	// return dstToOcean.x;
            	// return nonLinearDepth;
            	 // return non
            	// return dstThough;
            	float d2 = 1-(dstToAtmos / (dstThough2 * 2));
            	// float t =  saturate((1-(dstToAtmos / (dstThough2 * 2))));
            	// return nonLinearDepth * d2;
                // return d2;
            	float f = (min(d, sceneDepth));
            	// return mainLight.shadowAttenuation;

            	// d = sin(d);
            	float4 t = (calcLightTest(origin, rayDir));
            	// t *= d;
            	// t = min(t, sceneDepth);
            	return t;
            	return col * (1-t) + t;
            	// return col * (1-t) + t;

            	if(d2 < 1)
            	{
            		float3 pointInAtmosphere = origin + rayDir * (d);
            		float light = calcLight(pointInAtmosphere, rayDir, d);
            		
            		return col * (1-light) + light;
            	}
                // return col + f;
                // return col * (1-f) + f;
                return col;
            }
            ENDHLSL
        }
    	// Used for rendering shadowmaps
        UsePass "Universal Render Pipeline/Lit/ShadowCaster"
    }
}