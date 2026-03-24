Shader "Custom/HeatRaymarching_Glow_Turbulence"
{
    Properties
    {
        _Opacity ("Overall Opacity", Range(0, 10)) = 1.0
        _Contrast ("Heat Contrast", Range(0.1, 8)) = 3.0
        _StepSize ("Step Size", Range(0.01, 0.2)) = 0.05
        _GlowIntensity ("Glow Intensity (HDR)", Range(1, 10)) = 2.0
        _WaveSpeed ("Wave Speed", Range(0, 5)) = 0.5
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
                float4 screenPos : TEXCOORD1;
            };

            TEXTURE3D(_VolumeTexture);
            SAMPLER(sampler_VolumeTexture);
            float _Opacity, _Contrast, _StepSize, _IsCylinder, _GlowIntensity, _WaveSpeed;

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

            // 增强的 HDR 颜色映射
            float3 HeatToColor(float h)
            {
                h = smoothstep(0.0, 1.0, h);
                h = saturate(pow(h, _Contrast));

                float3 blue   = float3(0.0, 0.1, 0.5);
                float3 green  = float3(0.0, 0.6, 0.2);
                float3 yellow = float3(1.0, 0.7, 0.0);
                float3 red    = float3(1.0, 0.0, 0.0);

                float3 col;
                if (h < 0.25) col = lerp(blue, green, h / 0.25);
                else if (h < 0.5) col = lerp(green, yellow, (h - 0.25) / 0.25);
                else col = lerp(yellow, red, saturate((h - 0.5) / 0.5));

                // 如果温度很高（接近1.0），给它一个 HDR 乘数，让它发光
                float glowMask = smoothstep(0.6, 1.0, h);
                return col * (1.0 + glowMask * _GlowIntensity);
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

                float2 uv = IN.screenPos.xy / IN.screenPos.w;
                t += PseudoRandom(uv) * _StepSize;

                float bestHeat = 0;
                float bestWeight = 0;

                for(int i=0; i<128; i++) {
                    if(t >= tMax) break;
                    
                    float3 p = ro + rd * t;

                    // --- 核心优化：热波动动画 ---
                    // 使用 sin 函数模拟轻微的气流扰动
                    float noise = sin(p.x * 4.0 + _Time.y * _WaveSpeed) * cos(p.z * 4.0 + _Time.y * _WaveSpeed) * 0.02;
                    float3 animatedUVW = p + noise;

                    float3 uvw = animatedUVW;
                    if(_IsCylinder > 0.5) uvw.y *= 0.5;
                    uvw += 0.5; 

                    if(all(uvw >= 0) && all(uvw <= 1)) {
                        float2 data = SAMPLE_TEXTURE3D_LOD(_VolumeTexture, sampler_VolumeTexture, uvw, 0).xy;
                        if(data.x > bestHeat) bestHeat = data.x;
                        bestWeight = max(bestWeight, data.y);
                    }
                    t += _StepSize;
                }

                if(bestWeight < 0.01) discard;

                float3 finalRGB = HeatToColor(bestHeat);
                // 提高核心不透明度，让发光中心更扎实
                float finalAlpha = saturate(bestWeight * _Opacity * (1.0 + bestHeat));

                return half4(finalRGB, finalAlpha);
            }
            ENDHLSL
        }
    }
}