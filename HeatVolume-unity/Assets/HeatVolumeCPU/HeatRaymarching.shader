Shader "Custom/HeatRaymarching"
{
    Properties
    {
        [Header(General Settings)]
        _Opacity ("Overall Opacity", Range(0, 5)) = 1
        _ColorDist ("Focus Intensity (High is cleaner)", Range(0.1, 5)) = 1.0
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

            // --- 核心：聚焦色彩映射 ---
            float3 HeatToColor(float h)
            {
                float t = saturate(2*h);
                // 调节 ColorDist 参数可以控制冷色调占据的范围，数值越大，冷色越被压制
                float focusedT = pow(t, _ColorDist); 

                // 低温区：干净的深蓝到青色过渡 (0.0 -> 0.4)
                float3 col_low = lerp(float3(0.0, 0.05, 0.2), float3(0.0, 0.45, 0.65), smoothstep(0.0, 0.4, focusedT));
                
                // 高温区：丰富的彩虹色细节 (0.4 -> 1.0)
                float3 green  = float3(0.0, 1.0, 0.3);
                float3 yellow = float3(1.0, 0.9, 0.0);
                float3 orange = float3(1.0, 0.4, 0.0);
                float3 red    = float3(1.2, 0.0, 0.0);
                float3 white  = float3(2.0, 1.8, 1.5); // 过热点

                float3 col_high;
                if (focusedT < 0.55) col_high = lerp(green, yellow, (focusedT - 0.4) / 0.15);
                else if (focusedT < 0.75) col_high = lerp(yellow, orange, (focusedT - 0.55) / 0.2);
                else if (focusedT < 0.9) col_high = lerp(orange, red, (focusedT - 0.75) / 0.15);
                else col_high = lerp(red, white, (focusedT - 0.9) / 0.1);

                // 在 0.4 阈值附近平滑切换
                float3 finalCol = lerp(col_low, col_high, smoothstep(0.35, 0.45, focusedT));
                
                // 仅对真正的高温点（FocusedT > 0.65）施加辉光
                return finalCol * (1.0 + smoothstep(0.65, 1.0, focusedT) * _GlowIntensity);
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

                // 3. 移除低温透明化：现在透明度仅由数据权重和整体不透明度参数控制，保留完整体积感
                float alpha = saturate(maxWeight * _Opacity);
                
                return half4(HeatToColor(maxHeat), alpha);
            }
            ENDHLSL
        }
    }
}