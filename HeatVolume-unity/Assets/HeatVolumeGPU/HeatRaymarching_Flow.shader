Shader "Custom/HeatRaymarching_Flow"
{
    Properties
    {
        _Opacity ("Overall Opacity", Range(0, 5)) = 1.0
        _Contrast ("Heat Contrast", Range(1, 10)) = 2.0
        _StepSize ("Step Size", Range(0.01, 0.2)) = 0.05
        [Toggle] _IsCylinder("Is Cylinder Shape", Float) = 0
    }
    SubShader
    {
        Tags { "RenderType"="Transparent" "Queue"="Transparent" "RenderPipeline"="UniversalPipeline" }
        Blend One One 
        ZWrite Off
        Cull Front 

        Pass
        {
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes { float4 positionOS : POSITION; };
            struct Varyings { float4 positionCS : SV_POSITION; float3 positionOS : TEXCOORD0; };

            TEXTURE3D(_VolumeTexture);
            SAMPLER(sampler_VolumeTexture);
            float _Opacity, _Contrast, _StepSize, _IsCylinder;

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                OUT.positionCS = TransformObjectToHClip(IN.positionOS.xyz);
                OUT.positionOS = IN.positionOS.xyz;
                return OUT;
            }

            float3 HeatToColor(float h)
            {
                h = saturate(pow(h, _Contrast)); 
                float3 blue   = float3(0.0, 0.2, 1.0);
                float3 green  = float3(0.0, 1.0, 0.5);
                float3 yellow = float3(1.0, 0.9, 0.0);
                float3 red    = float3(1.0, 0.1, 0.0);
                if (h < 0.25) return lerp(blue, green, h / 0.25);
                if (h < 0.5)  return lerp(green, yellow, (h - 0.25) / 0.25);
                return lerp(yellow, red, saturate((h - 0.5) / 0.5));
            }

            // 动态 AABB 求交
            float2 RayBoxDist(float3 ro, float3 rd, float3 boxMin, float3 boxMax) {
                float3 t0 = (boxMin - ro) / rd;
                float3 t1 = (boxMax - ro) / rd;
                float3 tmin = min(t0, t1);
                float3 tmax = max(t0, t1);
                return float2(max(max(tmin.x, tmin.y), tmin.z), min(min(tmax.x, tmax.y), tmax.z));
            }

            half4 frag(Varyings IN) : SV_Target
            {
                float3 ro = TransformWorldToObject(_WorldSpaceCameraPos);
                float3 rd = normalize(IN.positionOS - ro);
                
                // 根据形状决定包围盒大小
                // Cube Y: [-0.5, 0.5] | Cylinder Y: [-1.0, 1.0]
                float yBound = (_IsCylinder > 0.5) ? 1.0 : 0.5;
                float3 bMin = float3(-0.5, -yBound, -0.5);
                float3 bMax = float3(0.5, yBound, 0.5);

                float2 hit = RayBoxDist(ro, rd, bMin, bMax);
                float t = max(0, hit.x);
                float tMax = hit.y;

                float4 finalColor = 0;
                for(int i=0; i<128; i++) {
                    if(t >= tMax) break;
                    float3 p = ro + rd * t;

                    // 动态映射 UVW
                    float3 uvw = p;
                    if(_IsCylinder > 0.5) uvw.y *= 0.5; // 只有圆柱体需要压缩Y
                    uvw += 0.5; 

                    if(all(uvw >= 0) && all(uvw <= 1)) {
                        float2 data = SAMPLE_TEXTURE3D_LOD(_VolumeTexture, sampler_VolumeTexture, uvw, 0).xy;
                        float heat = data.x;
                        float weight = data.y;
                        if(weight > 0.01) {
                            float3 c = HeatToColor(heat);
                            float alpha = weight * _StepSize * _Opacity;
                            finalColor.rgb += c * alpha; 
                            finalColor.a += alpha;
                        }
                    }
                    t += _StepSize;
                    if(finalColor.a >= 0.95) break;
                }
                return finalColor;
            }
            ENDHLSL
        }
    }
}