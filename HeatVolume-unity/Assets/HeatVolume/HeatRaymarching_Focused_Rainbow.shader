Shader "Custom/HeatRaymarching_Focused_Rainbow"
{
    Properties
    {
        _Opacity ("Overall Opacity", Range(0, 10)) = 1.0
        _ColorDist ("Color Distribution", Range(0.1, 5)) = 1.5
        _StepSize ("Step Size", Range(0.01, 0.2)) = 0.05
        _GlowIntensity ("Glow Intensity", Range(1, 10)) = 2.0
        _NoiseScale ("Fluid Scale", Range(0, 10)) = 2.5
        _NoiseSpeed ("Fluid Speed", Range(0, 2)) = 0.3
        _Distortion ("Distortion Strength", Range(0, 0.1)) = 0.015
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

            // --- 修正后的轻量级 3D Noise ---
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

            // --- 你的核心逻辑：聚焦高温区的色彩 ---
            float3 HeatToColor(float h)
            {
                float t = saturate(h);
                // 使用 ColorDist 压制低端颜色
                float focusedT = pow(t, _ColorDist); 

                // 低温区：深邃暗蓝到青蓝 (0.0 -> 0.4)
                float3 col_low = lerp(float3(0.0, 0.02, 0.15), float3(0.0, 0.5, 0.7), smoothstep(0.0, 0.4, focusedT));
                
                // 高温区：彩虹阶梯 (0.4 -> 1.0)
                float3 green  = float3(0.0, 1.0, 0.3);
                float3 yellow = float3(1.0, 0.9, 0.0);
                float3 orange = float3(1.0, 0.4, 0.0);
                float3 red    = float3(1.0, 0.0, 0.0);
                float3 white  = float3(1.8, 1.6, 1.3);

                float3 col_high;
                if (focusedT < 0.55) col_high = lerp(green, yellow, (focusedT - 0.4) / 0.15);
                else if (focusedT < 0.75) col_high = lerp(yellow, orange, (focusedT - 0.55) / 0.2);
                else if (focusedT < 0.92) col_high = lerp(orange, red, (focusedT - 0.75) / 0.17);
                else col_high = lerp(red, white, (focusedT - 0.92) / 0.08);

                // 混合：在 0.4 附近快速切换到彩虹色
                float3 finalCol = lerp(col_low, col_high, smoothstep(0.38, 0.42, focusedT));
                
                return finalCol * (1.0 + smoothstep(0.7, 1.0, focusedT) * _GlowIntensity);
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

                // 抖动防止色带
                t += (frac(sin(dot(IN.screenPos.xy/IN.screenPos.w, float2(12.9898, 78.233))) * 43758.5453)) * _StepSize;

                float maxHeat = 0;
                float maxWeight = 0;

                for(int i=0; i<85; i++) {
                    if(t >= tMax) break;
                    float3 p = ro + rd * t;

                    // 预采样温度以决定扰动强度
                    float3 checkUVW = p;
                    if(_IsCylinder > 0.5) checkUVW.y *= 0.5;
                    checkUVW += 0.5;
                    float hSample = SAMPLE_TEXTURE3D_LOD(_VolumeTexture, sampler_VolumeTexture, saturate(checkUVW), 0).x;

                    // 核心：扰动只影响热点区域，背景保持静止
                    float dFactor = _Distortion * smoothstep(0.3, 0.6, hSample);
                    float offset = noise(p * _NoiseScale - float3(0, _Time.y * _NoiseSpeed, 0)) * dFactor;
                    
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

                // 降低低温区的 Alpha，让蓝色背景更通透
                float alpha = maxWeight * _Opacity * smoothstep(0.15, 0.5, maxHeat);
                
                return half4(HeatToColor(maxHeat), alpha);
            }
            ENDHLSL
        }
    }
}