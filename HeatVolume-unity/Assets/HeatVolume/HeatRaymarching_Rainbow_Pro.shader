Shader "Custom/HeatRaymarching_Rainbow_Pro"
{
    Properties
    {
        _Opacity ("Overall Opacity", Range(0, 10)) = 1.0
        _Contrast ("Color Distribution", Range(0.1, 5)) = 1.0
        _StepSize ("Step Size", Range(0.01, 0.2)) = 0.05
        _GlowIntensity ("Glow Intensity (HDR)", Range(1, 10)) = 2.0
        _NoiseScale ("Fluid Noise Scale", Range(0, 10)) = 2.0
        _NoiseSpeed ("Fluid Noise Speed", Range(0, 2)) = 0.3
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
            float _Opacity, _Contrast, _StepSize, _IsCylinder, _GlowIntensity, _NoiseScale, _NoiseSpeed;

            // 快速噪声函数：增加流体感
            float SimpleNoise(float3 p) {
                float3 i = floor(p);
                float3 f = frac(p);
                f = f * f * (3.0 - 2.0 * f);
                float n = i.x + i.y * 57.0 + 113.0 * i.z;
                float4 res = lerp(
                    lerp(lerp(frac(sin(n + 0.0) * 43758.5453), frac(sin(n + 1.0) * 43758.5453), f.x),
                         lerp(frac(sin(n + 57.0) * 43758.5453), frac(sin(n + 58.0) * 43758.5453), f.x), f.y),
                    lerp(lerp(frac(sin(n + 113.0) * 43758.5453), frac(sin(n + 114.0) * 43758.5453), f.x),
                         lerp(frac(sin(n + 170.0) * 43758.5453), frac(sin(n + 171.0) * 43758.5453), f.x), f.y), f.z);
                return res.x;
            }

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                OUT.positionCS = TransformObjectToHClip(IN.positionOS.xyz);
                OUT.positionOS = IN.positionOS.xyz;
                OUT.screenPos = ComputeScreenPos(OUT.positionCS);
                return OUT;
            }

            // --- 核心优化：彩虹渐变函数 ---
            float3 HeatToColor(float h)
            {
                // 使用 smoothstep 做基础分布，不再使用强烈的 pow
                float t = saturate(h);
                if(_Contrast != 1.0) t = pow(t, 1.0 / _Contrast); 

                // 定义 7 个控制点 (0.0 到 1.0)
                float3 darkBlue = float3(0.0, 0.0, 0.5); // 0.0 深蓝
                float3 cyan     = float3(0.0, 0.8, 1.0); // 0.2 青色
                float3 green    = float3(0.0, 1.0, 0.2); // 0.4 绿色
                float3 yellow   = float3(1.0, 0.9, 0.0); // 0.6 黄色
                float3 orange   = float3(1.0, 0.4, 0.0); // 0.8 橙色
                float3 red      = float3(1.0, 0.0, 0.0); // 0.9 红色
                float3 white    = float3(1.5, 1.3, 1.1); // 1.0 白色核心

                float3 col;
                if (t < 0.2) col = lerp(darkBlue, cyan, t / 0.2);
                else if (t < 0.4) col = lerp(cyan, green, (t - 0.2) / 0.2);
                else if (t < 0.6) col = lerp(green, yellow, (t - 0.4) / 0.2);
                else if (t < 0.8) col = lerp(yellow, orange, (t - 0.6) / 0.2);
                else if (t < 0.92) col = lerp(orange, red, (t - 0.8) / 0.12);
                else col = lerp(red, white, (t - 0.92) / 0.08);

                // 只给高温区域增加辉光强度
                float glow = smoothstep(0.7, 1.0, t) * _GlowIntensity;
                return col * (1.0 + glow);
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

                // Jitter 抖动噪声
                float2 uvScreen = IN.screenPos.xy / IN.screenPos.w;
                t += (frac(sin(dot(uvScreen, float2(12.9898, 78.233))) * 43758.5453)) * _StepSize;

                float bestHeat = 0;
                float bestWeight = 0;

                for(int i=0; i<96; i++) {
                    if(t >= tMax) break;
                    float3 p = ro + rd * t;

                    // 动态噪声扰动
                    float noise = SimpleNoise(p * _NoiseScale + _Time.y * _NoiseSpeed) * 0.04;
                    float3 uvw = p + noise;
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
                
                // 增强低温区域的可见性，高温区域更厚重
                float alphaBoost = lerp(0.8, 1.2, bestHeat);
                float finalAlpha = saturate(bestWeight * _Opacity * alphaBoost);

                return half4(finalRGB, finalAlpha);
            }
            ENDHLSL
        }
    }
}