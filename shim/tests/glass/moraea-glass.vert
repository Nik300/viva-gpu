#version 120
#define lowp
#define mediump
#define highp
#define NOISE_SIZE 32

uniform highp mat4 vertex_matrix;
uniform highp vec4 texmat0, texmat1, texmat2;
uniform highp vec4 texmatD;
uniform highp vec4 texmatW;
attribute highp vec4 vertex_position;
attribute lowp vec4 vertex_color;
attribute highp vec2 vertex_texcoord0, vertex_texcoord1;
attribute mediump vec3 vertex_normal;
varying lowp vec4 color;
varying highp vec2 texcoord0_0;
varying highp vec2 texcoord1_0;
varying highp vec3 texcoordD;
varying highp vec3 texcoordN;

varying highp vec2 cg9m_v0, cg9m_v1;
void main() {
  cg9m_v0 = vertex_texcoord0;
  cg9m_v1 = vertex_texcoord1;
  gl_Position = vertex_matrix * vertex_position;
  color = vertex_color;
  texcoord0_0 = vertex_texcoord0 * texmat0.xy + texmat0.zw;
  texcoord1_0 = vertex_texcoord1 * texmat1.xy + texmat1.zw;
  texcoordD = vec3(gl_Position.xy * texmatD.xy + texmatD.zw * gl_Position.w, gl_Position.w);
  texcoordN = vec3(gl_Position.xy * texmatW.xy + texmatW.zw * gl_Position.w, gl_Position.w * float(NOISE_SIZE));
}
