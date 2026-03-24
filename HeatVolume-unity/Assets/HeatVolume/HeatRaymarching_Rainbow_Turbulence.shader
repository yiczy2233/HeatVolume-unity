Shader "Custom/HeatRaymarching_Rainbow_Turbulence"
{
    Properties
    {
        _Opacity ("Overall Opacity", Range(0, 10)) = 1.0
        _ColorDist ("Color Distribution", Range(0.1, 5)) = 1.0
        _StepSize ("Step Size", Range(0.01, 0.2)) = 0.05
        _GlowIntensity ("Glow Intensity (HDR)", Range(1, 10)) = 2.0
        _NoiseScale ("Fluid Scale", Range(0, 10)) = 4.0 // 稍微调高一点
        _NoiseSpeed ("Fluid Speed", Range(0, 2)) = 0.5
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
            float _Opacity, _ColorDist, _StepSize, _IsCylinder, _GlowIntensity, _NoiseScale, _NoiseSpeed;

            // 增强优化点 1：平滑的 3D Gradient Noise (Simplex-like)
            float Fade(float t) { return t * t * t * (t * (t * 6.0 - 15.0) + 10.0); }
            float Grad(int hash, float x, float y, float z) {
                int h = hash & 15;
                float u = h < 8 ? x : y;
                float v = h < 4 ? y : h == 12 || h == 14 ? x : z;
                return ((h & 1) == 0 ? u : -u) + ((h & 2) == 0 ? v : -v);
            }

            float GradientNoise(float3 p) {
                float3 i = floor(p);
                float3 f = frac(p);
                float3 w = Fade(f);
                
                int n = (int)i.x + (int)i.y * 57 + (int)i.z * 113;
                
                // 简单的伪随机哈希
                float4 h = sin(float4(n, n+1, n+57, n+58)) * 43758.5453;
                float4 h2 = sin(float4(n+113, n+114, n+170, n+171)) * 43758.5453;
                
                return lerp(lerp(lerp(Grad((int)h.x, f.x, f.y, f.z), Grad((int)h.y, f.x-1, f.y, f.z), w.x),
                                lerp(Grad((int)h.z, f.x, f.y-1, f.z), Grad((int)h.w, f.x-1, f.y-1, f.z), w.x), w.y),
                            lerp(lerp(Grad((int)h2.x, f.x, f.y, f.z-1), Grad((int)h2.y, f.x-1, f.y, f.z-1), w.x),
                                lerp(Grad((int)h2.z, f.x, f.y-1, f.z-1), Grad((int)h2.w, f.x-1, f.y-1, f.z-1), w.x), w.y), w.z);
            }

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                OUT.positionCS = TransformObjectToHClip(IN.positionOS.xyz);
                OUT.positionOS = IN.positionOS.xyz;
                OUT.screenPos = ComputeScreenPos(OUT.positionCS);
                return OUT;
            }

            // 彩虹渐变函数 (保持之前的均衡)
            float3 HeatToColor(float h)
            {
                float t = saturate(h);
                if(_ColorDist != 1.0) t = pow(t, 1.0 / _ColorDist); 

                float3 darkBlue = float3(0.0, 0.0, 0.4); 
                float3 cyan     = float3(0.0, 0.8, 1.0); 
                float3 green    = float3(0.0, 1.0, 0.2); 
                float3 yellow   = float3(1.0, 0.9, 0.0); 
                float3 orange   = float3(1.0, 0.4, 0.0); 
                float3 red      = float3(1.0, 0.0, 0.0); 
                float3 white    = float3(1.5, 1.3, 1.1); 

                float3 col;
                if (t < 0.2) col = lerp(darkBlue, cyan, t / 0.2);
                else if (t < 0.4) col = lerp(cyan, green, (t - 0.2) / 0.2);
                else if (t < 0.6) col = lerp(green, yellow, (t - 0.4) / 0.2);
                else if (t < 0.8) col = lerp(yellow, orange, (t - 0.6) / 0.2);
                else if (t < 0.92) col = lerp(orange, red, (t - 0.8) / 0.12);
                else col = lerp(red, white, (t - 0.92) / 0.08);

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

                float2 uvScreen = IN.screenPos.xy / IN.screenPos.w;
                t += (frac(sin(dot(uvScreen, float2(12.9898, 78.233))) * 43758.5453)) * _StepSize;

                float bestHeat = 0;
                float bestWeight = 0;

                // 核心优化点 2：全向涡流采样循环
                for(int i=0; i<112; i++) {
                    if(t >= tMax) break;
                    float3 p = ro + rd * t;

                    // 计算动画偏移
                    float time = _Time.y * _NoiseSpeed;
                    float3 nCoord = p * _NoiseScale;
                    
                    // --- 核心优化部分 ---
                    // 1. 纵向整体升腾
                    nCoord.y -= time;
                    // 2. 引入 XZ 轴的涡流抖动 (Turbulence)
                    // 使用 cos 函数让噪声块在水平面上做微小的全向摇摆，模拟流体内卷和撕裂
                    float3 turbulence = float3(
                        GradientNoise(nCoord + float3(time, 0, 0)) * 0.1, // X轴全向扯动
                        0, // Y轴不动（由上面nCoord.y统一升腾）
                        GradientNoise(nCoord + float3(0, 0, time)) * 0.1  // Z轴全向扯动
                    );
                    
                    float noise = GradientNoise(nCoord + turbulence) * 0.06;
                    
                    // 应用这个全向噪声到采样坐标上
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
                
                // 透明度调整：低温区更透明，高温区扎实
                float alphaBoost = lerp(0.6, 1.3, bestHeat);
                float finalAlpha = saturate(bestWeight * _Opacity * alphaBoost);

                return half4(finalRGB, finalAlpha);
            }
            ENDHLSL
        }
    }
}