Shader "Custom/HeatRaymarching_Final_Professional1"
{
    Properties
    {
        [Header(General Settings)]
        _Opacity ("Overall Opacity", Range(0, 10)) = 1.5
        _ColorDist ("Focus Intensity (High is cleaner)", Range(0.1, 5)) = 2.0
        _StepSize ("Raymarching Step Size", Range(0.01, 0.2)) = 0.05
        
        [Header(Visual Effects)]
        _GlowIntensity ("Hot Spot Glow (HDR)", Range(1, 10)) = 2.5
        _NoiseScale ("Fluid Pattern Scale", Range(0, 10)) = 2.2
        _NoiseSpeed ("Fluid Rise Speed", Range(0, 2)) = 0.3
        _Distortion ("Hot Spot Turbulence", Range(0, 0.1)) = 0.015
        
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
            float _Opacity, _ColorDist, _StepSize, _IsCylinder, _GlowIntensity, _NoiseScale, _NoiseSpeed, _Distortion;

            // --- 鲁棒性 3D 噪声实现 ---
            float hash(float n) { return frac(sin(n) * 43758.5453); }
            
            float noise(float3 x) {
                float3 p = floor(x);
                float3 f = frac(x);
                f = f * f * (3.0 - 2.0 * f);
                float n = p.x + p.y * 57.0 + 113.0 * p.z;
                return lerp(lerp(lerp(hash(n + 0.0), hash(n + 1.0), f.x),
                                 lerp(hash(n + 57.0), hash(n + 58.0), f.x), f.y),
                            lerp(lerp(hash(n + 113.0), hash(n + 114.0), f.x),
                                 lerp(hash(n + 170.0), hash(n + 171.0), f.x), f.y), f.z);
            }

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                OUT.positionCS = TransformObjectToHClip(IN.positionOS.xyz);
                OUT.positionOS = IN.positionOS.xyz;
                OUT.screenPos = ComputeScreenPos(OUT.positionCS);
                return OUT;
            }

            // --- 核心修改：离散色带映射 (Hex to RGB) ---
            float3 HeatToColor(float h)
            {
                // VolumeTexture 中存的范围是 0.0 - 1.0，放大回 0 - 100 实际温度
                float temp = saturate(h) * 100.0;
                
                // 基于提供的 JSON 严格执行阶梯色带逻辑
                if (0.5f*temp >= 40.0) return float3(0.596, 0.020, 0.000); // #980500 
                if (0.5f*temp >= 38.0) return float3(0.627, 0.035, 0.004); // #a00901 
                if (0.5f*temp >= 36.0) return float3(0.765, 0.047, 0.008); // #c30c02 
                if (0.5f*temp >= 34.0) return float3(0.859, 0.306, 0.000); // #db4e00 
                if (0.5f*temp >= 32.0) return float3(0.945, 0.553, 0.008); // #f18d02 
                if (0.5f*temp >= 30.0) return float3(0.925, 0.788, 0.020); // #ecc905 
                if (0.5f*temp >= 28.0) return float3(0.914, 0.925, 0.020); // #e9ec05 
                if (0.5f*temp >= 26.0) return float3(0.706, 0.843, 0.063); // #b4d710 
                if (0.5f*temp >= 24.0) return float3(0.439, 0.749, 0.000); // #70bf00 
                if (0.5f*temp >= 22.0) return float3(0.051, 0.749, 0.000); // #0dbf00 
                if (0.5f*temp >= 20.0) return float3(0.063, 0.820, 0.008); // #10d102 
                if (0.5f*temp >= 18.0) return float3(0.004, 0.894, 0.318); // #01e451 
                if (0.5f*temp >= 16.0) return float3(0.000, 0.761, 0.643); // #00c2a4 
                if (0.5f*temp >= 14.0) return float3(0.294, 0.796, 0.855); // #4bcbda 
                if (0.5f*temp >= 12.0) return float3(0.365, 0.824, 0.996); // #5dd2fe 
                if (0.5f*temp >= 10.0) return float3(0.118, 0.753, 0.992); // #1ec0fd 
                if (0.5f*temp >= 8.0)  return float3(0.169, 0.639, 0.992); // #2ba3fd 
                if (0.5f*temp >= 6.0)  return float3(0.004, 0.486, 0.851); // #017cd9 
                if (0.5f*temp >= 4.0)  return float3(0.000, 0.408, 0.718); // #0068b7 
                if (0.5f*temp >= 2.0)  return float3(0.000, 0.278, 0.616); // #00479d 
                
                return float3(0.000, 0.161, 0.365); // #00295d (0 - 2)
            }

            half4 frag(Varyings IN) : SV_Target
            {
                float3 ro = TransformWorldToObject(_WorldSpaceCameraPos);
                float3 rd = normalize(IN.positionOS - ro);
                float yBound = (_IsCylinder > 0.5) ? 1.0 : 0.5;
                float3 bMin = float3(-0.5, -yBound, -0.5);
                float3 bMax = float3(0.5, yBound, 0.5);

                float3 t0 = (bMin - ro) / rd;
                float3 t1 = (bMax - ro) / rd;
                float tMax = min(min(max(t0.x, t1.x), max(t0.y, t1.y)), max(t0.z, t1.z));
                float t = max(0, max(max(min(t0.x, t1.x), min(t0.y, t1.y)), min(t0.z, t1.z)));
                
                // 屏幕抖动，消除采样层线感
                t += (frac(sin(dot(IN.screenPos.xy/IN.screenPos.w, float2(12.9898, 78.233))) * 43758.5453)) * _StepSize;
                
                float maxHeat = 0;
                float maxWeight = 0;

                for(int i=0; i<85; i++) {
                    if(t >= tMax) break;
                    float3 p = ro + rd * t;

                    // 1. 预采样基础温度
                    float3 checkUVW = p;
                    if(_IsCylinder > 0.5) checkUVW.y *= 0.5;
                    checkUVW += 0.5;
                    float hSample = SAMPLE_TEXTURE3D_LOD(_VolumeTexture, sampler_VolumeTexture, saturate(checkUVW), 0).x;
                    
                    // 2. 根据温度计算扰动：低温静止，高温飘动
                    float activeDist = _Distortion * smoothstep(0.3, 0.7, hSample);
                    float offset = noise(p * _NoiseScale - float3(0, _Time.y * _NoiseSpeed, 0)) * activeDist;
                    
                    float3 uvw = p + offset;
                    if(_IsCylinder > 0.5) uvw.y *= 0.5;
                    uvw += 0.5;

                    if(all(uvw >= 0) && all(uvw <= 1)) {
                        float2 data = SAMPLE_TEXTURE3D_LOD(_VolumeTexture, sampler_VolumeTexture, uvw, 0).xy;
                        maxHeat = max(maxHeat, data.x);
                        maxWeight = max(maxWeight, data.y);
                    }
                    t += _StepSize;
                }

                if(maxWeight < 0.02) discard;
                
                // 3. 透明度优化：调整了下限 (0.05 -> 0.3)，保证 15度 以下的蓝绿色带依然清晰可见
                float alpha = maxWeight * _Opacity * smoothstep(0.05, 0.3, maxHeat);
                
                // 4. 获取硬过渡色带并叠加辉光 (仅高温区)
                float3 finalCol = HeatToColor(maxHeat);
                finalCol *= (1.0 + smoothstep(0.38, 1.0, maxHeat) * _GlowIntensity); // 38度以上开始有HDR泛光
                
                return half4(finalCol, alpha);
            }
            ENDHLSL
        }
    }
}