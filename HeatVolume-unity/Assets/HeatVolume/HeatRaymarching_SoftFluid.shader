Shader "Custom/HeatRaymarching_SoftFluid"
{
    Properties
    {
        _Opacity ("Overall Opacity", Range(0, 10)) = 1.0
        _ColorDist ("Color Distribution", Range(0.1, 5)) = 1.0
        _StepSize ("Step Size", Range(0.01, 0.2)) = 0.05
        _GlowIntensity ("Glow Intensity", Range(1, 10)) = 2.0
        _NoiseScale ("Fluid Scale", Range(0, 10)) = 2.5
        _NoiseSpeed ("Fluid Speed", Range(0, 2)) = 0.3
        _Distortion ("Distortion Strength", Range(0, 0.1)) = 0.02 // 新增：控制撕裂程度
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

            // 使用更稳定的低频噪声
            float3 mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
            float4 mod289(float4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
            float4 permute(float4 x) { return mod289(((x*34.0)+1.0)*x); }
            float snoise(float3 v) {
                const float2 C = float2(1.0/6.0, 1.0/3.0);
                const float4 D = float4(0.0, 0.5, 1.0, 2.0);
                float3 i  = floor(v + dot(v, C.yyy));
                float3 x0 = v - i + dot(i, C.xxx);
                float3 g = step(x0.yzx, x0.xyz);
                float3 l = 1.0 - g;
                float3 i1 = min( g.xyz, l.zxy );
                float3 i2 = max( g.xyz, l.zxy );
                float3 x1 = x0 - i1 + C.xxx;
                float3 x2 = x0 - i2 + C.yyy;
                float3 x3 = x0 - D.yyy;
                i = mod289(i);
                float4 p = permute( permute( permute( i.z + float4(0.0, i1.z, i2.z, 1.0 )) + i.y + float4(0.0, i1.y, i2.y, 1.0 )) + i.x + float4(0.0, i1.x, i2.x, 1.0 ));
                float4 j = p - 49.0 * floor(p * (1.0 / 49.0));
                float4 x_ = floor(j * (1.0 / 7.0));
                float4 y_ = floor(j - 7.0 * x_ );
                float4 x = x_ * (1.0/7.0) + 0.5/7.0;
                float4 y = y_ * (1.0/7.0) + 0.5/7.0;
                float4 h = 1.0 - abs(x) - abs(y);
                float4 b0 = float4( x.xy, y.xy );
                float4 b1 = float4( x.zw, y.zw );
                float4 s0 = floor(b0)*2.0 + 1.0;
                float4 s1 = floor(b1)*2.0 + 1.0;
                float4 sh = -step(h, float4(0,0,0,0));
                float4 a0 = b0.xzyw + s0.xzyw*sh.xxyy ;
                float4 a1 = b1.xzyw + s1.xzyw*sh.zzww ;
                float3 p0 = float3(a0.xy,h.x);
                float3 p1 = float3(a0.zw,h.y);
                float3 p2 = float3(a1.xy,h.z);
                float3 p3 = float3(a1.zw,h.w);
                float4 norm = 1.79284291400159 - 0.85373472095314 * float4(dot(p0,p0), dot(p1,p1), dot(p2,p2), dot(p3,p3));
                p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;
                float4 m = max(0.6 - float4(dot(x0,x0), dot(x1,x1), dot(x2,x2), dot(x3,x3)), 0.0);
                m = m * m;
                return 42.0 * dot( m*m, float4( dot(p0,x0), dot(p1,x1), dot(p2,x2), dot(p3,x3) ) );
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

                return col * (1.0 + smoothstep(0.7, 1.0, t) * _GlowIntensity);
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

                // Jitter
                float2 uvScreen = IN.screenPos.xy / IN.screenPos.w;
                t += (frac(sin(dot(uvScreen, float2(12.9898, 78.233))) * 43758.5453)) * _StepSize;

                float bestHeat = 0;
                float bestWeight = 0;

                for(int i=0; i<96; i++) {
                    if(t >= tMax) break;
                    float3 p = ro + rd * t;

                    // --- 优化点：更柔和的流体逻辑 ---
                    // 1. 降低噪声频率
                    float3 nCoord = p * _NoiseScale;
                    float time = _Time.y * _NoiseSpeed;
                    
                    // 2. 使用 Simplex Noise 产生多维偏移，但严格限制偏移量 (_Distortion)
                    float offset = snoise(nCoord - float3(0, time, 0)) * _Distortion;
                    
                    float3 uvw = p + offset;
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
                float finalAlpha = saturate(bestWeight * _Opacity * lerp(0.7, 1.2, bestHeat));

                return half4(finalRGB, finalAlpha);
            }
            ENDHLSL
        }
    }
}