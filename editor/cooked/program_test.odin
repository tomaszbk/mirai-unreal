package cooked

import "core:mem"
import "core:strings"
import "core:testing"

@(private="file")
PROGRAM_DESCRIPTION :: `{"Material":"MI_Floor","CodeHash":"00112233aabbccdd",
"Pixel":{"Shader":"003_Pixel","Function":"dx_pixel","Source":"pixel.slang",
 "Inputs":[{"Id":0,"Semantic":"TEXCOORD10_centroid","Index":0,"Rows":1,"Integer":false,"Used":true},
           {"Id":1,"Semantic":"TEXCOORD","Index":0,"Rows":2,"Integer":false,"Used":true},
           {"Id":2,"Semantic":"SV_Position","Index":0,"Rows":1,"Integer":false,"Used":true}],
 "Outputs":[{"Id":0,"Semantic":"SV_Target","Index":0,"Rows":1,"Integer":false,"Used":true},
            {"Id":1,"Semantic":"SV_Target","Index":1,"Rows":1,"Integer":false,"Used":true},
            {"Id":2,"Semantic":"SV_Target","Index":2,"Rows":1,"Integer":false,"Used":true},
            {"Id":3,"Semantic":"SV_Target","Index":3,"Rows":1,"Integer":false,"Used":true}],
 "UniformBuffers":[{"Name":"View","Layout":"VIEW_LAYOUT"},{"Name":"Scene","Layout":"f7e1b302"},{"Name":"Material","Layout":"01020304"}],
 "Bindings":[{"Kind":"Constant_Buffer","Slot":2,"Buffer":"Material","Size":64,"Registers":[3,1]},
             {"Kind":"Constant_Buffer","Slot":0,"Buffer":"View","Size":6796,"Registers":[44,163]},
             {"Kind":"Raw_Buffer","Slot":1,"Buffer":"Scene","Resource":5},
             {"Kind":"Texture","Slot":4,"Buffer":"Material","Resource":2},
             {"Kind":"Sampler","Slot":0,"Buffer":"View","Resource":0}]},
"Vertex":{"Shader":"001_Vertex","Function":"dx_vertex","Source":"vertex.slang",
 "Inputs":[{"Id":0,"Semantic":"ATTRIBUTE","Index":0,"Rows":1,"Integer":false,"Used":true},
           {"Id":1,"Semantic":"SV_VertexID","Index":0,"Rows":1,"Integer":true,"Used":true}],
 "Outputs":[{"Id":0,"Semantic":"SV_Position","Index":0,"Rows":1,"Integer":false,"Used":false},
            {"Id":1,"Semantic":"TEXCOORD","Index":0,"Rows":2,"Integer":false,"Used":true}],
 "UniformBuffers":[{"Name":"View","Layout":"VIEW_LAYOUT"},{"Name":"Scene","Layout":"f7e1b302"},{"Name":"LocalVF","Layout":"3aef5598"}],
 "Bindings":[{"Kind":"Constant_Buffer","Slot":2,"Buffer":"LocalVF","Size":148,"Registers":[0]},
             {"Kind":"Buffer","Slot":7,"Buffer":"LocalVF","Resource":0}]},
"Parameters":{"Name":"MI_Floor","Evaluated":{"UniformBuffer":[[0,0,0,0],[1,2,3,4],[0,0,0,0],[0.5,0.25,0,1]],
 "TextureBindings":[{"Slot":0,"Texture":"/Game/T_Unused.T_Unused"},{"Slot":1,"Texture":"/Game/T_Floor_D.T_Floor_D"}]}}}`

@(private="file")
PROGRAM_VERTEX :: `void dx_vertex(inout Dx_Env e) {
int v1=0;
D v2=d_c(0.0);
int4 v3=int4(0);
D4 v4=(D4)0;
v1=dx_input_i(e,1,0,0);
v2=dx_input(e,0,0,2);
v3=dx_cb_i(e,2,0);
v4=dx_buffer(e,7,v1);
dx_output(e,1,0,0,v4.x);
dx_output(e,1,1,3,v2);
}
`

@(private="file")
PROGRAM_PIXEL :: `void dx_pixel(inout Dx_Env e) {
D v1=d_c(0.0);
float4 v2=float4(0.0);
v1=dx_input(e,1,1,3);
v2=dx_cb(e,2,3);
v2=dx_cb(e,0,44);
v2=dx_raw(e,1,(18),0);
v2=dx_sample(e,4,0,v1,v1,0.0);
if (v1.v<0.0) dx_discard(e);
dx_output(e,3,0,2,d_c(v2[0]));
}
`

@(test)
cooked_shader_program_answers_what_its_functions_read :: proc(t:^testing.T) {
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,context.allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    alloc:=mem.tracking_allocator(&tracking)

    description,_:=strings.replace_all(PROGRAM_DESCRIPTION,"VIEW_LAYOUT","cfe9c681",context.temp_allocator)
    p,err:=cooked_shader_program(description,PROGRAM_PIXEL,PROGRAM_VERTEX,alloc)
    _,bad:=err.?
    if !testing.expect(t,!bad,"a program of known layouts builds") {return}
    testing.expect_value(t,p.name,"Unreal_00112233aabbccdd")
    testing.expect_value(t,len(p.notes),0)
    // Parameters: the texture the shaders sample, then the registers they read, in order.
    if testing.expect_value(t,len(p.parameters),3) {
        testing.expect_value(t,p.parameters[0].name,"t1")
        testing.expect_value(t,p.parameters[0].texture,"/Game/T_Floor_D.T_Floor_D")
        testing.expect_value(t,p.parameters[1].name,"m1")
        testing.expect_value(t,p.parameters[1].value,[4]f32{1,2,3,4})
        testing.expect_value(t,p.parameters[2].name,"m3")
        testing.expect_value(t,p.parameters[2].value,[4]f32{0.5,0.25,0,1})
    }
    wants:=[]string{
        "//! mirai surface Unreal_00112233aabbccdd",
        "//! parameter t1 {\"kind\":\"texture\"}",
        "    uint t1;\n    float4 m1;\n    float4 m3;\n",
        "v1=int(e.vin[4].v);",          // SV_VertexID, the second vertex input
        "v2=e.vin[2];",
        "v3=dx_localvf(0);",
        "v4=dx_fetch_uv(e,v1);",
        "e.pin[4]=v4.x;",               // the vertex function writes the pixel function's TEXCOORD
        "e.pin[11]=v2;",
        "v1=e.pin[11];",
        "v2=e.p.m3;",
        "v2=dx_view(e,44);",
        "v2=dx_primitive(e,(18));",
        "v2=dx_tex_sample(e.p.t1,v1,v1,0.0);",
        "if (v1.v<0.0) e.discarded=true;",
        "e.pout[14]=d_c(v2[0]);",
        "e.vin[0] = e.local[0];",
        "e.pin[0] = d_c(e.tangent[0]);",
        "e.pin[12] = d_make(e.pixel.x, 1.0, 0.0);",
        "s.base_color = saturate(float3(e.pout[12].v, e.pout[13].v, e.pout[14].v));",
    }
    for want in wants {
        testing.expectf(t,strings.contains(p.source,want),"the program has %q",want)
    }
    testing.expect(t,!strings.contains(p.source,"dx_input")&&!strings.contains(p.source,"dx_output")&&!strings.contains(p.source,"dx_cb"),"no call is left unanswered")
    cooked_shader_program_destroy(&p,alloc)
    testing.expect_value(t,len(tracking.allocation_map),0)

    // An engine buffer of another layout is refused, not read wrong.
    other,_:=strings.replace_all(PROGRAM_DESCRIPTION,"VIEW_LAYOUT","deadbeef",context.temp_allocator)
    _,err=cooked_shader_program(other,PROGRAM_PIXEL,PROGRAM_VERTEX,alloc)
    e,refused:=err.?
    testing.expect(t,refused&&strings.contains(e.detail,"View"),"another layout of the view is refused")
    testing.expect_value(t,len(tracking.allocation_map),0)

    // Hostile input ends in an error or a program, never a crash or a leak.
    hostile:=[][3]string{
        {"","",""},
        {"{","",""},
        {"[]","",""},
        {`{"CodeHash":"../x"}`,"",""},
        {`{"CodeHash":"00"}`,"",""},
        {`{"CodeHash":"00","Pixel":{"Inputs":[{"Rows":999999999}],"Outputs":[{}]},"Vertex":7}`,"dx_input(e,0,99,0)",""},
        {description,"v1=dx_input(e,1,1","v=dx_output(e"},
        {description,"v1=dx_input(e,v9,0,0);",""},
        {description,"dx_output(e,3,0);",""},
        {description,"v=dx_sample(e,99,0,a,b,c);v=dx_raw(e,9,1,0);v=dx_buffer(e,(-3),1);v=dx_unknown(e);",""},
        {description,PROGRAM_PIXEL,"dx_output(e,0,0,0,v);"},
    }
    for h in hostile {
        got,_:=cooked_shader_program(h[0],h[1],h[2],alloc)
        cooked_shader_program_destroy(&got,alloc)
    }
    testing.expect_value(t,len(tracking.allocation_map),0)
}
