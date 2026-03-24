Shader "Custom/HeatRaymarching_Jitter_Smooth"
{
    Properties
    {
        _Opacity ("Overall Opacity", Range(0, 5)) = 1.0
        _Contrast ("Heat Contrast", Range(0.1, 8)) = 3.0
        _StepSize ("Step Size", Range(0.01, 0.2)) = 0.05
        [Toggle] _IsCylinder("Is Cylinder Shape", Float) = 0
    }
    SubShader
    {
        Tags { "RenderType"="Transparent" "Queue"="Transparent" "RenderPipeline"="UniversalPipeline" }
        Blend SrcAlpha OneMinusSrcAlpha 
        ZWrite Off
        Cull Front 

        Pass
        {
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes { float4 positionOS : POSITION; };
            struct Varyings { 
                float4 positionCS : SV_POSITION; 
                float3 positionOS : TEXCOORD0; 
                float4 screenPos : TEXCOORD1; // 增加屏幕坐标用于计算随机噪声
            };

            TEXTURE3D(_VolumeTexture);
            SAMPLER(sampler_VolumeTexture);
            float _Opacity, _Contrast, _StepSize, _IsCylinder;

            // 简单的随机函数，用于计算 Jitter
            float PseudoRandom(float2 uv) {
                return frac(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453);
            }

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                OUT.positionCS = TransformObjectToHClip(IN.positionOS.xyz);
                OUT.positionOS = IN.positionOS.xyz;
                OUT.screenPos = ComputeScreenPos(OUT.positionCS);
                return OUT;
            }

            // 优化的颜色映射，引入 Smoothstep
            float3 HeatToColor(float h)
            {
                // 使用 smoothstep 让冷热交界处更加丝滑
                h = smoothstep(0.0, 1.0, h);
                h = saturate(pow(h, _Contrast));

                float3 blue   = float3(0.0, 0.2, 0.8);
                float3 green  = float3(0.0, 0.8, 0.4);
                float3 yellow = float3(1.0, 0.9, 0.0);
                float3 red    = float3(1.0, 0.0, 0.0);

                if (h < 0.25) return lerp(blue, green, h / 0.25);
                if (h < 0.5)  return lerp(green, yellow, (h - 0.25) / 0.25);
                return lerp(yellow, red, saturate((h - 0.5) / 0.5));
            }

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

                float yBound = (_IsCylinder > 0.5) ? 1.0 : 0.5;
                float3 bMin = float3(-0.5, -yBound, -0.5);
                float3 bMax = float3(0.5, yBound, 0.5);

                float2 hit = RayBoxDist(ro, rd, bMin, bMax);
                float t = max(0, hit.x);
                float tMax = hit.y;

                // --- Jitter 优化：根据屏幕像素坐标给起始位置一个随机偏移 ---
                float2 uv = IN.screenPos.xy / IN.screenPos.w;
                float offset = PseudoRandom(uv) * _StepSize;
                t += offset;

                float bestHeat = 0;
                float bestWeight = 0;

                // Raymarching 循环
                for(int i=0; i<128; i++) {
                    if(t >= tMax) break;
                    
                    float3 p = ro + rd * t;
                    float3 uvw = p;
                    if(_IsCylinder > 0.5) uvw.y *= 0.5;
                    uvw += 0.5; 

                    if(all(uvw >= 0) && all(uvw <= 1)) {
                        float2 data = SAMPLE_TEXTURE3D_LOD(_VolumeTexture, sampler_VolumeTexture, uvw, 0).xy;
                        
                        // 高温优先逻辑
                        if(data.x > bestHeat) {
                            bestHeat = data.x;
                        }
                        bestWeight = max(bestWeight, data.y);
                    }
                    t += _StepSize;
                }

                if(bestWeight < 0.01) discard;

                // 应用平滑后的颜色
                float3 finalRGB = HeatToColor(bestHeat);
                
                // 最终透明度，使用权重结合全局透明度
                float finalAlpha = saturate(bestWeight * _Opacity);

                return half4(finalRGB, finalAlpha);
            }
            ENDHLSL
        }
    }
}