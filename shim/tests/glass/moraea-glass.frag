#version 120
#extension GL_ARB_shader_texture_lod : enable
#define lowp
#define mediump
#define highp
#define NOISE_SIZE 32

uniform highp vec4 texmat0, texmat1, texmat2;
uniform mediump float noise_scale;
uniform lowp sampler2DRect texture0;
uniform lowp sampler2D texture1;
varying highp vec2 texcoord0_0;
varying highp vec3 texcoordN;

#define CG9M_T0(t) texture2DRect(texture0, t)
#define CG9M_S0 cg9m_g[21].xy
#define CG9M_N0 cg9m_g[21].zw
uniform highp vec4 cg9m_g[26];
highp float cg9m_ramp(highp float amt, highp float invh, highp float nd) {
  highp float x = clamp(invh * nd, 0.0, 1.0);
  return amt - clamp(sqrt((2.0 - x) * x), 0.0, 1.0) * amt;
}
highp vec2 cg9m_nrm(highp vec2 v, highp vec2 f) {
  highp float l = dot(v, v);
  return l > 0.0 ? v * inversesqrt(l) : f;
}
#define CG9M_CM(u, k) vec3(dot(u, cg9m_g[k].rgb), dot(u, cg9m_g[k + 1].rgb), dot(u, cg9m_g[k + 2].rgb))
#define CG9M_CA(k) vec3(cg9m_g[k].a, cg9m_g[k + 1].a, cg9m_g[k + 2].a)
uniform sampler2D cg9m_mipT;
highp float cg9m_lodf(highp float r) {
  return log2(max(r < 2.0 ? r * 0.5 + 1.0 : r, 1.0));
}
highp vec4 cg9m_mip(highp vec2 t, highp float lod) {
  if (lod < 0.25) return CG9M_T0(t);
  highp float L = floor(lod);
  highp float v = 1.453 * exp2(2.0 * L) * (1.0 + 3.0 * (lod - L)) - 1.287;
  highp float m = 0.5 * log2(max(12.0 * v, 1.0));
#ifdef GL_ARB_shader_texture_lod
  return texture2DLod(cg9m_mipT, t * CG9M_N0, m);
#else
  highp vec2 dx = dFdx(t), dy = dFdy(t);
  return texture2D(cg9m_mipT, t * CG9M_N0, m - 0.5 * log2(max(max(dot(dx, dx), dot(dy, dy)), 1e-8)));
#endif
}
highp vec3 cg9m_clean(highp vec3 c) {
  return vec3(abs(c.r) < 1e-6 ? 0.0 : c.r, abs(c.g) < 1e-6 ? 0.0 : c.g, abs(c.b) < 1e-6 ? 0.0 : c.b);
}
varying highp vec2 cg9m_v0, cg9m_v1;
highp vec3 cg9m_sc(highp vec2 p, highp vec2 hs, highp float rad, highp vec2 m) {
  highp float R = abs(rad), Rs = R * 1.528665;
  highp vec2 q = p - hs + mix(Rs, R, max(m.x, m.y));
  highp vec2 u = max(vec2(0.0), (p - hs + Rs) / Rs);
  highp float len = length(u), a = max(u.x, u.y), b = min(u.x, u.y);
  highp float t = a == 0.0 ? 0.0 : clamp(b / a, 0.0, 1.0);
  highp float poly = (((3.15601 - t * 0.926054) * t - 3.64122) * t + 1.26803) * t + 0.268531;
  highp float e = len + 1.0 - 1.0 / (1.0 - t * t * clamp(len, 0.0, 1.0) * poly);
  highp float g = length(max(vec2(0.0), u * 1.528665 - 0.528665)) * 0.65416557 + 0.34583443;
  highp float s = u.y > u.x ? 1.0 : -1.0;
  highp float dd = mix(mix(e, g, m.x), mix(e, g, m.y), clamp(0.5 - s + s * t, 0.0, 1.0)) - 1.0;
  highp vec2 n = cg9m_nrm(max(vec2(0.0), q), q.x > q.y ? vec2(1.0, 0.0) : vec2(0.0, 1.0));
  return vec3(min(max(q.x, q.y), 0.0) + Rs * dd, n);
}
highp vec3 cg9m_sdf(highp vec2 p, highp float mode) {
  highp vec4 A = cg9m_g[23], T = cg9m_g[24], B = cg9m_g[25];
  highp vec2 sg = vec2(p.x >= 0.0 ? 1.0 : -1.0, p.y >= 0.0 ? 1.0 : -1.0);
  highp vec3 r;
  if (mode < 4.0) {
    highp vec2 q = abs(p) - A.xy;
    r = vec3(max(q.x, q.y), (q.x > q.y ? vec2(1.0, 0.0) : vec2(0.0, 1.0)) * sg);
  } else if (mode == 4.0) {
    r = cg9m_sc(abs(p), A.xy, B.z, B.xy);
    r.yz *= sg;
  } else {
    highp vec4 h = (B.xxwy + B.ywzz) * 0.5;
    highp vec4 w = mix(vec4(1.0), clamp((A.xyxy / h + 1.528665) * 1.8915572, 0.0, 1.0), vec4(lessThan(h, vec4(0.0))));
    r = cg9m_sc(p, A.xy, B.y, w.xw);
    highp vec3 k = cg9m_sc(vec2(-p.x, p.y), A.xy, B.x, w.xy);
    if (k.x > r.x) r = vec3(k.x, -k.y, k.z);
    k = cg9m_sc(vec2(p.x, -p.y), A.xy, B.z, w.zw);
    if (k.x > r.x) r = vec3(k.x, k.y, -k.z);
    k = cg9m_sc(-p, A.xy, B.w, w.zy);
    if (k.x > r.x) r = vec3(k.x, -k.y, -k.z);
  }
  highp vec2 n = cg9m_nrm(mix(r.yz, cg9m_nrm(vec2(p.x, A.x * p.y / A.y), r.yz), A.w), r.yz);
  return vec3(r.x, dot(n, T.xy), dot(n, T.zw));
}
highp vec4 cg9m_gb(highp vec2 t0, highp vec2 sh, highp float d, highp vec2 g, highp float cov, bool bleed) {
  highp vec2 disp = vec2(dot(g, cg9m_g[0].xy), dot(g, cg9m_g[0].zw)) * CG9M_S0;
  highp vec4 o = vec4(0.0), r = vec4(0.0);
  if (cov < 1.0) {
    highp float e = clamp(cg9m_g[4].w * sh.x * 0.25 + 0.5, 0.0, 1.0) * 4.0 - 2.0, e2 = e * e;
    highp float k = cg9m_g[18].y * sh.y * ((((0.002954 * e2 - 0.03445) * e2 + 0.1682) * e2 - 0.5605) * e + 0.5);
    if (k < 1e-6 && cov == 0.0) discard;
    if (cg9m_g[14].x > 1e-6) {
      highp vec4 c = cg9m_mip(t0 + cg9m_ramp(cg9m_g[3].z, cg9m_g[3].w, -(cg9m_g[18].x + d)) * disp, cg9m_lodf(cg9m_g[4].z));
      highp vec3 u = cg9m_clean(c.rgb / max(c.a, 1e-6));
      o = vec4(CG9M_CM(u, 11) * cg9m_g[14].x + CG9M_CA(11), mix(cg9m_g[14].y, 1.0, cg9m_g[14].x));
    } else
      o = vec4(CG9M_CA(11), cg9m_g[14].y);
    o *= k;
  }
  if (cov > 0.0) {
    highp vec4 c;
    if (cg9m_g[20].z != 0.0) {
      highp vec3 d0 = vec3(cg9m_g[15].zw, cg9m_g[16].x), d1 = vec3(cg9m_g[15].w, cg9m_g[16].xy);
      highp vec3 ba = vec3(cg9m_g[14].w, cg9m_g[15].xy);
      highp float a1 = cg9m_ramp(cg9m_g[1].x, cg9m_g[1].y, -d);
      highp vec3 w = clamp((a1 + d - d0) / (d1 - d0), 0.0, 1.0) * ba;
      c = cg9m_mip(t0 + a1 * disp, cg9m_lodf((cg9m_g[14].z - w.x - w.y - w.z) * cg9m_g[2].z));
      c.rgb = cg9m_clean(c.rgb);
      if (cg9m_g[18].z > 0.0) {
        highp float a2 = cg9m_ramp(cg9m_g[1].z, cg9m_g[1].w, -d);
        w = clamp((a2 + d - d0) / (d1 - d0), 0.0, 1.0) * ba;
        highp vec4 c2 = cg9m_mip(t0 + a2 * disp, cg9m_lodf((cg9m_g[14].z - w.x - w.y - w.z) * cg9m_g[2].z));
        c2.rgb = cg9m_clean(c2.rgb);
        c = mix(c, c2, clamp((d - cg9m_g[2].x) / (cg9m_g[2].y - cg9m_g[2].x), 0.0, 1.0) * cg9m_g[18].z);
      }
    } else {
      c = cg9m_mip(t0, cg9m_lodf(cg9m_g[2].z));
      c.rgb = cg9m_clean(c.rgb);
    }
    highp vec3 f = c.rgb / max(c.a, 1e-6);
    if (cg9m_g[17].y > 0.0) f = mix(f, CG9M_CM(f, 5) + CG9M_CA(5), cg9m_g[17].y);
    if (bleed) {
      highp vec4 b = cg9m_mip(t0 + cg9m_ramp(cg9m_g[3].x, cg9m_g[3].y, -d) * disp, cg9m_lodf(cg9m_g[2].w));
      highp vec3 bu = cg9m_clean(b.rgb / max(b.a, 1e-6));
      highp float q = cg9m_g[17].z * clamp(dot(f, vec3(0.2125, 0.7154, 0.0721)), 0.0, 1.0) + cg9m_g[17].w;
      q = q * q * clamp((d - cg9m_g[16].z) / (cg9m_g[16].w - cg9m_g[16].z), 0.0, 1.0);
      f = mix(f, CG9M_CM(bu, 8) + CG9M_CA(8), q * q * cg9m_g[17].x);
    }
    r = vec4(f, 1.0);
  }
  r = mix(o, r, cov);
  if (cg9m_g[18].w > 0.0) {
    highp float h = cg9m_g[19].x > d ? 1.0 :
                    !(cg9m_g[19].y <= d) ? 1.0 - (d - cg9m_g[19].x) / (cg9m_g[19].y - cg9m_g[19].x) : 0.0;
    highp float a = clamp(r.a, 0.0, 1.0);
    r = mix(r, vec4(cg9m_g[20].x * r.rgb * a / max(r.a, 1e-6), a), h * cg9m_g[18].w);
  }
  if (cg9m_g[19].z > 0.0) {
    highp vec3 u = r.rgb / max(r.a, 1e-6);
    if (cg9m_g[19].w > 0.0) {
      highp float m = max(max(u.r, u.g), u.b);
      if (m > cg9m_g[19].z) u *= cg9m_g[19].z / m;
    } else
      u = clamp(u, -0.75, cg9m_g[19].z);
    r.rgb = u * r.a;
  }
  return r;
}
highp vec4 cg9m_gbs(bool bleed) {
  highp float mode = cg9m_g[23].z < 0.0 ? ceil(cg9m_g[23].z) : floor(cg9m_g[23].z);
  highp vec3 s = mode > -1.0 ? cg9m_sdf(cg9m_v0, mode) : vec3(0.0);
  highp float cov = mode > -1.0 ? clamp(0.5 - s.x / max(fwidth(s.x), 1e-4), 0.0, 1.0) : 0.0;
  highp vec2 sh = vec2(0.0);
  if (cov < 1.0) {
    highp float m = abs(mode);
    sh = vec2(cg9m_sdf(cg9m_v0 + cg9m_g[4].xy, mod(floor(m / 4.0), 2.0) >= 1.0 ? m : m + 4.0).x, 1.0);
  }
  return cg9m_gb(cg9m_v1 * CG9M_S0, sh, s.x, s.yz, cov, bleed);
}

void main(void) {
  lowp vec4 s0 = texture2DRect(texture0, texcoord0_0);
  gl_FragData[0] = cg9m_gbs(false);
  {
    mediump vec3 n = texture2DProj(texture1, texcoordN).xyz;
    n = (n - .5) * noise_scale;
    lowp vec3 c = gl_FragData[0].rgb + n*gl_FragData[0].a;
    gl_FragData[0].rgb = clamp(c, 0., gl_FragData[0].a);
  }
}
