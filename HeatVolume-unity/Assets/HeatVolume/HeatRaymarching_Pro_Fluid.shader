Shader "Custom/HeatRaymarching_Pro_Safe"
{
    Properties
    {
        _Opacity ("Overall Opacity", Range(0, 10)) = 1.0
        _Contrast ("Heat Contrast", Range(0.1, 8)) = 3.0
        _StepSize ("Step Size", Range(0.01, 0.2)) = 0.05
        _GlowIntensity ("Glow Intensity", Range(1, 10)) = 2.0
        _NoiseScale ("Noise Scale", Range(0, 10)) = 2.0
        _NoiseSpeed ("Noise Speed", Range(0, 2)) = 0.3
        [Toggle] _IsCylinder("Is Cylinder Shape", Float) = 0
    }
    SubShader
    {
        // 核心：标准透明度混合，不依赖深度贴图
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

            // 轻量级噪声，用于流体感
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

            float3 HeatToColor(float h)
            {
                // Contrast 决定了低温背景的可见度
                h = saturate(pow(h, _Contrast));
                float3 blue = float3(0.0, 0.1, 0.7);
                float3 green = float3(0.0, 0.7, 0.3);
                float3 yellow = float3(1.0, 0.8, 0.0);
                float3 red = float3(1.0, 0.0, 0.0);

                float3 col;
                if (h < 0.25) col = lerp(blue, green, h / 0.25);
                else if (h < 0.5) col = lerp(green, yellow, (h - 0.25) / 0.25);
                else col = lerp(yellow, red, saturate((h - 0.5) / 0.5));

                // HDR 增益：只让高温(红色)部分发光
                float glow = smoothstep(0.6, 1.0, h) * _GlowIntensity;
                return col * (1.0 + glow);
            }

            // Ray-Box 求交，确保渲染范围限制在 Box 内
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

                // Jitter 抖动消除色带
                float2 uvScreen = IN.screenPos.xy / IN.screenPos.w;
                t += (frac(sin(dot(uvScreen, float2(12.9898, 78.233))) * 43758.5453)) * _StepSize;

                float bestHeat = 0;
                float bestWeight = 0;

                // 核心 Raymarching 循环
                for(int i=0; i<96; i++) {
                    if(t >= tMax) break;
                    
                    float3 p = ro + rd * t;

                    // 引入噪声流体扰动
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
                // 这里移除了 softEdge 计算，改为纯权重控制
                float finalAlpha = saturate(bestWeight * _Opacity);

                return half4(finalRGB, finalAlpha);
            }
            ENDHLSL
        }
    }
}