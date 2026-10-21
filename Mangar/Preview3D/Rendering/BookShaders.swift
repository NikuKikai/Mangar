import Foundation

enum BookShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms { float4 pose; float4 paper; float4 frontUV; float4 backUV; float4 stack; float4 shape; };
    struct Surface { float3 position; float3 normal; float2 uv; };
    struct Out { float4 position [[position]]; float2 uv; float3 normal; float4 lightPosition; };
    float3 rotateBook(float3 p, float yaw, float pitch) {
        p = float3(p.x*cos(yaw)+p.z*sin(yaw), p.y, -p.x*sin(yaw)+p.z*cos(yaw));
        return float3(p.x, p.y*cos(pitch)-p.z*sin(pitch), p.y*sin(pitch)+p.z*cos(pitch));
    }
    float3 lightDirection() { return normalize(float3(-0.65,0.5,1)); }
    float4 lightPosition(float3 p, constant Uniforms &u) {
        float3 l=lightDirection();
        float3 right=normalize(cross(float3(0,1,0),l));
        float3 up=cross(l,right);
        float span=max(2.0,u.paper.z)*1.4;
        return float4(dot(p,right)/span,dot(p,up)/span,0.5-dot(p,l)/(span*4),1);
    }
    Surface bookSurface(float2 uv, constant Uniforms &u) {
        float t=uv.x, angle=M_PI_F*u.paper.y;
        float bend=sin(angle)*1.25*u.shape.y, a=angle-bend*0.5;
        float x=t*cos(angle), z=t*sin(angle);
        if (abs(bend) > 0.0001) {
            x=(sin(a+bend*t)-sin(a))/bend;
            z=(cos(a)-cos(a+bend*t))/bend;
        }
        // A raised shoulder on each side of a real recessed gutter. Its
        // analytic derivative drives both lighting and the deformed normal.
        float e=exp(-t/0.085), edge=1-t;
        float h=u.shape.x*(1-e)*edge*edge;
        float dh=u.shape.x*(e/0.085*edge*edge-2*(1-e)*edge);
        float theta=a+bend*t, side=u.paper.x;
        float3 p=float3(side*x+u.stack.x,(0.5-uv.y)*u.paper.z+u.stack.y,z+h+u.paper.w*smoothstep(0.0,0.12,t));
        float liftT=clamp(t/0.12,0.0,1.0);
        float liftDerivative=t < 0.12 ? u.paper.w*6*liftT*(1-liftT)/0.12 : 0;
        float3 n=normalize(float3(-side*(sin(theta)+dh+liftDerivative),0,cos(theta)));
        Surface s;
        // Camera and world light stay fixed; gestures rotate the book mesh.
        s.position=rotateBook(p,u.pose.x,u.pose.y);
        s.normal=rotateBook(n,u.pose.x,u.pose.y); s.uv=uv;
        return s;
    }
    vertex Out bookVertex(uint id [[vertex_id]], const device float2 *grid [[buffer(0)]],
                          constant Uniforms &u [[buffer(1)]]) {
        Surface s=bookSurface(grid[id],u);
        Out o;
        o.position=float4(s.position.x*u.pose.z/u.pose.w,s.position.y*u.pose.z,0.5-s.position.z*0.12,1);
        o.uv=s.uv; o.normal=s.normal; o.lightPosition=lightPosition(s.position,u);
        return o;
    }
    vertex float4 bookShadowVertex(uint id [[vertex_id]], const device float2 *grid [[buffer(0)]],
                                  constant Uniforms &u [[buffer(1)]]) {
        return lightPosition(bookSurface(grid[id],u).position,u);
    }
    struct SpineVertex { float4 position; float4 normal; };
    Surface spineSurface(SpineVertex input, constant Uniforms &u) {
        float x=input.position.x*u.shape.z, t=abs(x), edge=1-t, e=exp(-t/0.085);
        float top=u.shape.x*(1-e)*edge*edge-0.0007;
        float derivative=u.shape.x*(e/0.085*edge*edge-2*(1-e)*edge)*sign(x);
        float extension=u.stack.y;
        float3 p=float3(x,input.position.y*(u.paper.z+extension)-extension*0.5,top-input.position.z*u.shape.w);
        float3 n=input.normal.xyz;
        if (n.z > 0.5) n=normalize(float3(-derivative,0,1));
        Surface s; s.position=rotateBook(p,u.pose.x,u.pose.y);
        s.normal=rotateBook(n,u.pose.x,u.pose.y); s.uv=float2(0.5);
        return s;
    }
    vertex Out bookSpineVertex(uint id [[vertex_id]], const device SpineVertex *vertices [[buffer(0)]],
                               constant Uniforms &u [[buffer(1)]]) {
        Surface s=spineSurface(vertices[id],u);
        Out o; o.position=float4(s.position.x*u.pose.z/u.pose.w,s.position.y*u.pose.z,0.5-s.position.z*0.12,1);
        o.uv=s.uv; o.normal=s.normal; o.lightPosition=lightPosition(s.position,u); return o;
    }
    vertex float4 bookSpineShadowVertex(uint id [[vertex_id]], const device SpineVertex *vertices [[buffer(0)]],
                                       constant Uniforms &u [[buffer(1)]]) {
        return lightPosition(spineSurface(vertices[id],u).position,u);
    }
    fragment float4 bookFragment(Out in [[stage_in]], constant Uniforms &u [[buffer(1)]],
                                texture2d<float> front [[texture(0)]], texture2d<float> back [[texture(1)]],
                                depth2d<float> shadow [[texture(2)]]) {
        constexpr sampler s(filter::linear,mip_filter::linear,address::clamp_to_edge);
        constexpr sampler comparison(coord::normalized,filter::linear,address::clamp_to_edge,compare_func::less_equal);
        bool facing=in.normal.z >= 0;
        float x=u.paper.x < 0 ? 1-in.uv.x : in.uv.x;
        if (!facing) x=1-x;
        float4 region=facing ? u.frontUV : u.backUV;
        float2 uv=float2(mix(region.x,region.y,x),in.uv.y);
        float4 c=facing ? front.sample(s,uv) : back.sample(s,uv);
        float3 n=normalize(facing ? in.normal : -in.normal);
        float diffuse=max(0.0,dot(n,lightDirection()));
        float2 shadowUV=in.lightPosition.xy*float2(0.5,-0.5)+0.5;
        // Receiver-plane depth correction keeps a curved sheet from shadowing
        // itself due to depth-map texel quantization, especially at the gutter.
        float2 dx=dfdx(shadowUV), dy=dfdy(shadowUV);
        float zx=dfdx(in.lightPosition.z), zy=dfdy(in.lightPosition.z);
        float determinant=dx.x*dy.y-dx.y*dy.x;
        float2 gradient=abs(determinant)>1e-10 ? float2(zx*dy.y-zy*dx.y,zy*dx.x-zx*dy.x)/determinant : float2(0);
        float2 texel=1.0/float2(shadow.get_width(),shadow.get_height());
        float bias=0.00025+min(0.006,dot(abs(gradient),texel)*0.85);
        float visibility=0;
        for (int y=-1;y<=1;y++) for (int x=-1;x<=1;x++) {
            float2 offset=float2(x,y)*texel;
            visibility+=shadow.sample_compare(comparison,shadowUV+offset,in.lightPosition.z+dot(gradient,offset)-bias);
        }
        visibility/=9;
        float light=0.30+0.70*diffuse*visibility;
        return float4((c.rgb+(1-c.a))*light*u.stack.z,1);
    }
    """
}
