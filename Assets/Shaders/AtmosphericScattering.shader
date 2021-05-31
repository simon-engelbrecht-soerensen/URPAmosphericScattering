Shader "Universal Render Pipeline/Custom/AtmosphericScattering"
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

            const float earth_radius = 6360e3; // (m)
			const float atmosphere_radius = 6420e3; // (m)

            const float sun_power = 20.0;
			struct RayT
            {
			    float3 origin;
			    float3 direction;
			};
            
			struct SphereT
            {
			    float3 origin;
			    float radius;
			};
            
			float rayleigh_phase_func(float mu){
			    return 3.*(1.+mu*mu)/(16.*PI);
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

            	//A beloved classic
			const float g = 0.76;
			float henyey_greenstein_phase_func(float mu)
			{
				return
									(1. - g*g)
				/ //---------------------------------------------
					((4. * PI) * pow(1. + g*g - 2.*g*mu, 1.5));
			}


			float3 sunDir;

            //if ray intersects atmosphere/Sphere
            bool IntersectsWithSphere(RayT ray, SphereT sphere, inout float t0, inout float t1)
			{
				float3 rc = sphere.origin - ray.origin;
				float radius2 = sphere.radius * sphere.radius;
				float tca = dot(rc, ray.direction);
				float d2 = dot(rc, rc) - tca * tca;
				if (d2 > radius2) return false;
				float thc = sqrt(radius2 - d2);
				t0 = tca - thc;
				t1 = tca + thc;

				return true;
			}

            bool get_sun_light(RayT ray, inout float optical_depthR, inout float optical_depthM)
            {
				float t0, t1;
            	SphereT atmosphere;
            	atmosphere.origin = 0;
            	atmosphere.radius = atmosphere_radius;
            	
				IntersectsWithSphere(ray, atmosphere, t0, t1);

				float march_pos = 0.;
				float march_step = t1 / float(_OpticalDepthPoints);

				for (int i = 0; i < _OpticalDepthPoints; i++) {
					float3 s =
						ray.origin +
						ray.direction * (march_pos + 0.5 * march_step);
					float height = length(s) - earth_radius;
					if (height < 0.)
						return false;

					optical_depthR += exp(-height / hR) * march_step;
					optical_depthM += exp(-height / hM) * march_step;

					march_pos += march_step;
				}

				return true;
			}
            float3 get_incident_light(RayT ray)
			{
				// "pierce" the atmosphere with the viewing ray
				float t0, t1;
            	SphereT atmosphere;
            	atmosphere.origin = 0;
            	atmosphere.radius = atmosphere_radius;
				if (!IntersectsWithSphere(ray, atmosphere, t0, t1))
				{
					return 0;
				}

				float march_step = t1 / float(_ScatteringPoints);

				// cosine of angle between view and light directions
				float mu = dot(ray.direction, sunDir);

				// Rayleigh and Mie phase functions
				// A black box indicating how light is interacting with the material
				// Similar to BRDF except
				// * it usually considers a single angle
				//   (the phase angle between 2 directions)
				// * integrates to 1 over the entire sphere of directions
				float phaseR = rayleigh_phase_func(mu);
				float phaseM =
			#if 1
					henyey_greenstein_phase_func(mu);
			#else
					schlick_phase_func(mu);
			#endif

				// optical depth (or "average density")
				// represents the accumulated extinction coefficients
				// along the path, multiplied by the length of that path
				float optical_depthR = 0.;
				float optical_depthM = 0.;

				float3 sumR = 0;
				float3 sumM = 0;
				float march_pos = 0.;

				for (int i = 0; i < _ScatteringPoints; i++) {
					float3 s =
						ray.origin +
						ray.direction * (march_pos + 0.5 * march_step);
					float height = length(s) - earth_radius;

					// integrate the height scale
					float hr = exp(-height / hR) * march_step;
					float hm = exp(-height / hM) * march_step;
					optical_depthR += hr;
					optical_depthM += hm;

					// gather the sunlight
					RayT light_ray;
					// = _begin(ray_t)
					// 	s,
					// 	sun_dir
					// _end;
					light_ray.origin = s;
					light_ray.direction = sunDir;
					
					float optical_depth_lightR = 0.;
					float optical_depth_lightM = 0.;
					bool overground = get_sun_light(
						light_ray,
						optical_depth_lightR,
						optical_depth_lightM);

					if (overground) {
						float3 tau =
							betaR * (optical_depthR + optical_depth_lightR) +
							betaM * 1.1 * (optical_depthM + optical_depth_lightM);
						float3 attenuation = exp(-tau);

						sumR += hr * attenuation;
						sumM += hm * attenuation;
					}

					march_pos += march_step;
				}

				return
					sun_power *
					(sumR * phaseR * betaR +
					sumM * phaseM * betaM);
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

            	RayT ray;
            	ray.origin = origin;
            	ray.direction = rayDir;
            	
            	float4 col = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, IN.uv);
					
            	sunDir = normalize(_MainLightPosition.xyz);
            	// return length;
            	return float4(get_incident_light(ray), 1);
            	return col;
            	
            }
            ENDHLSL
        }
    	// Used for rendering shadowmaps
    }
}