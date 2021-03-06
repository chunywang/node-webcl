#define MAX_WORKGROUP_SIZE 256

typedef struct {
  float3 origin;
  float r;
  float2 dis;
} Sphere; // 4*(3+1+2)=24 bytes aligned to 32 bytes

typedef struct {
  float3 origin;
  float3 dir;
  float3 nor;
  float4 col;
  float fovfactor;
  float t;
  float3 rgb;
  Sphere sph;
} __attribute__((aligned(16))) Ray; // aligned to 128 bytes

// forward declarations
bool isphere( __local Ray *ray );
bool iterate( const float3 q, float *resPot, float4 *resColor );
bool ifractal( __local Ray *ray);

inline bool isphere( __local Ray *ray ) {
  const float3 oc = ray->origin - ray->sph.origin;
  const float b = dot(oc,ray->dir);
  const float c = dot(oc,oc) - ray->sph.r*ray->sph.r;

  const float h = b*b - c;
  if( h<0 )
    return false;

  const float g = native_sqrt( h );
  ray->sph.dis = (float2) ( - b - g, - b + g);

  return true;
}

__constant const int NumIte=8;
__constant const float Bailout=100.f;
__constant const float EPS=0.001f;
__constant const float MAXT=1.e20f;
__constant const float3 light1 = (float3)( 0.577f, 0.577f, 0.577f );
__constant const float3 light2 = (float3)( -0.707f, 0, 0.707f );
__constant const float3 material1=(float3)(0.8f,0.6f,0.2f);
__constant const float3 material2=(float3)(0.8f,0.3f,0.3f);
__constant const float3 material3=(float3)(0.7f,0.4f,0.3f);

inline bool iterate( const float3 q, float *resPot, float4 *resColor ) {
  float4 trap = (float4)(100.f);
  float3 zz = q;
  float m = dot(zz,zz);

  if( m > Bailout ) {
    *resPot = 0.5f*native_log(m);
    *resColor = (float4)(1.f);
    return false;
  }

  *resPot = 0;

  float x, x2, x4;
  float y, y2, y4;
  float z, z2, z4 ;
  float k1,k2,k3,k4;

//#pragma unroll 2
  for( int i=0; i<NumIte; i++ ) {
    x = zz.x; x2 = x*x; x4 = x2*x2;
    y = zz.y; y2 = y*y; y4 = y2*y2;
    z = zz.z; z2 = z*z; z4 = z2*z2;

    k3 = x2 + z2;
    k2 = rsqrt( k3*k3*k3*k3*k3*k3*k3 );
    k1 = x4 + y4 + z4 - 6*y2*z2 - 6*x2*y2 + 2*z2*x2;
    k4 = x2 - y2 + z2;

    zz.x = q.x + 64.f*x*y*z*(x2-z2)*k4*(x4-6.f*x2*z2+z4)*k1*k2;
    zz.y = q.y + -16.f*y2*k3*k4*k4 + k1*k1;
    zz.z = q.z + -8.f*y*k4*(x4*x4 - 28.f*x4*x2*z2 + 70.f*x4*z4 - 28.f*x2*z2*z4 + z4*z4)*k1*k2;

    m = dot(zz,zz);

    trap = min( trap, (float4)(zz.xyz*zz.xyz, m) );

    if( m > Bailout ) {
      *resPot = 0.5f*native_log(m)/native_powr(8.0f,i);
      break;
    }
  }

  *resColor = trap;
  return (m<=Bailout);
}

inline bool ifractal(__local Ray *ray) {
  __local Sphere *sph=&ray->sph;
  sph->origin = (float3)(0.f);
  sph->r = 1.25f;

  // bounding sphere
  if( !isphere(ray) ) return false;

  // early skip
  if( sph->dis.y<EPS ) return false;

  // clip to near!
  if( sph->dis.x<EPS ) sph->dis.x = EPS;

  if( sph->dis.y>MAXT) sph->dis.y = MAXT;

  float dt;
  float3 gra;
  float4 color, col2;
  float pot1, pot2, pot3, pot4;

  // raymarch!
  float t=sph->dis.x, Surface, eps;
  float3 p = ray->origin + ray->dir * t;

  while(t < sph->dis.y) {
    if( iterate(p,&pot1,&color) ) {
      ray->t = t;
      ray->nor = fast_normalize(gra);
      ray->col = color;
      return true;
    }

    Surface = clamp( EPS*t*ray->fovfactor, 0.000001f, 0.005f );
    eps = Surface*0.1f;

    iterate(p+(float3)(eps,0.0f,0.0f),&pot2,&col2);
    iterate(p+(float3)(0.0f,eps,0.0f),&pot3,&col2);
    iterate(p+(float3)(0.0f,0.0f,eps),&pot4,&col2);

    gra = (float3)( pot2-pot1, pot3-pot1, pot4-pot1 );
    dt = 0.5f*pot1*eps/fast_length(gra);

    if( dt<Surface ) {
      ray->col = color;
      ray->nor = fast_normalize( gra );
      ray->t = t;
      return true;
    }

    t += dt;
    p += ray->dir * dt;
  }

  return false;
}

// Note: autovectorize assuming float4 as the basic computation width
__kernel /*__attribute__((vec_type_hint(float4)))*/
void compute(__write_only image2d_t pix, const float time) {
  const int x = get_global_id(0);
  const int y = get_global_id(1);
  const int xl = get_local_id(0);
  const int yl = get_local_id(1);
  const int tid = xl+yl*get_local_size(0);
  const int width = get_global_size(0);
  const int height = get_global_size(1);

  const float2 resolution = (float2)(width,height);
  const float2 gl_FragCoord = (float2)(x,y);

  const float2 p = (float2)(-1.f + 2.f * gl_FragCoord / resolution);
  const float2 s = p*(float2)(1.33f,1.0f);

  const float fov = 0.5f, fovfactor = rsqrt(1.0f+fov*fov);

  const float ct=native_cos(2.f*M_PI_F*time/20.f), st=native_sin(2.f*M_PI_F*time/20.f);
  const float r = 1.4f+0.2f*ct;
  const float3 campos = (float3)( r*st, 0.3f-0.4f*st, r*ct ); // camera origin
  const float3 camtar = (float3)(0.f,0.1f,0.f); // camera target

  //camera matrix
  const float3 cw = fast_normalize(camtar-campos);
  const float3 cp = (float3)(0.f,1.f,0.f);
  const float3 cu = fast_normalize(cross(cw,cp));
  const float3 cv = fast_normalize(cross(cu,cw));

  // ray
  __local Ray rays[MAX_WORKGROUP_SIZE+1], *ray=rays+tid;
  ray->origin=campos; // camera is at ray origin
  ray->dir = fast_normalize( s.x*cu + s.y*cv + 1.5f*cw );
  ray->fovfactor = fovfactor;
  ray->rgb = (float3)(1.f);

  //barrier(CLK_LOCAL_MEM_FENCE);
  const bool res=ifractal(ray);

  if( !res ) {
    // background color
    ray->rgb = 1.3f*(float3)(1.f,0.98f,0.9f)*(0.7f+0.3f*ray->dir.y);
  }
  else {
    // intersection point
    const float3 xyz = ray->origin + ray->t * ray->dir;

    // sun light
    float dif1 = clamp( 0.2f + 0.8f*dot( light1, ray->nor ), 0.f, 1.f );
    dif1=dif1*dif1;

    // back light
    const float dif2 = clamp( 0.3f + 0.7f*dot( light2, ray->nor ), 0.f, 1.f );

    // ambient occlusion
    const float aot = clamp(1.25f*ray->col.w-.4f, 0.f, 1.f);
    const float ao=0.5f*aot*(aot+1);

    // shadow: cast a lightray from intersection point
    if( dif1 > EPS ) {
      __local Ray *lray=rays+MAX_WORKGROUP_SIZE;
      lray->origin=xyz;
      lray->dir=light1;
      lray->fovfactor = fovfactor;
      if( ifractal(lray) )
        dif1 = 0.1f;
    }

    // material color
    ray->rgb = mix( ray->rgb, material1, (float3)(native_sqrt(ray->col.x)*1.25f) );
    ray->rgb = mix( ray->rgb, material2, (float3)(native_sqrt(ray->col.y)*1.25f) );
    ray->rgb = mix( ray->rgb, material3, (float3)(native_sqrt(ray->col.z)*1.25f) );

    // lighting
    ray->rgb *= (0.5f+0.5f * ray->nor.y)*
                 (float3)(.14f,.15f,.16f)*0.8f +
                 dif1*(float3)(1.0f,.85f,.4f) +
                 0.5f*dif2*(float3)(.08f,.10f,.14f);
    ray->rgb *= (float3)( native_powr(ao,0.8f), native_powr(ao,1.0f), native_powr(ao,1.1f) );

    // gamma
    ray->rgb = 1.5f*(ray->rgb*0.15f + 0.85f*native_sqrt(ray->rgb));
  }

  const float2 uv = 0.5f*(p+1.f);
  ray->rgb *= 0.7f + 0.3f*16.f*uv.x*uv.y*(1.f-uv.x)*(1.f-uv.y);
  ray->rgb = clamp( ray->rgb, (float3)(0.f), (float3)(1.f) );

  //barrier(CLK_LOCAL_MEM_FENCE);
  write_imagef(pix,(int2)(x,y),(float4)(ray->rgb,1.0f));
}
