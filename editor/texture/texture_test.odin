package unreal_texture

import "core:encoding/endian"
import "core:testing"
import "mirai:cook/textures"
import "project:plugins/unreal/editor/kraken"
import unreal "project:plugins/unreal/editor/package"

// A UE4 522 package with one Texture2D and its source inline as UE4 bulk data.

@(private="file")
NAMES :: [?]string{
    "None","/Script/Engine","Package","Texture2D","Class","T_Test","/Game/T_Test",
    "Source","StructProperty","TextureSource","SizeX","IntProperty","SizeY","NumSlices","NumMips",
    "Format","ByteProperty","ETextureSourceFormat","CompressionFormat","ETextureSourceCompressionFormat",
    "CompressionSettings","TextureCompressionSettings","SRGB","BoolProperty",
    "TSF_G8","TSF_BGRA8","TSF_RGBA16","TSF_RGBA16F","TSCF_None","TSCF_UEDELTA","TSCF_UEJPEG","TC_Default","TC_Normalmap","TC_Masks",
    "TextureCube","Texture2DArray","TSF_BGRE8","TC_HDR","TC_Grayscale",
}

@(private="file")
name_index :: proc(name:string) -> u32 {
    names:=NAMES
    for candidate,i in names {if candidate==name {return u32(i)}}
    panic("fixture name")
}

@(private="file")
Writer :: struct {bytes:[dynamic]u8}

@(private="file") u16_put :: proc(w:^Writer,value:u16) {append(&w.bytes,u8(value),u8(value>>8))}
@(private="file") u32_put :: proc(w:^Writer,value:u32) {for i in 0..<4 {append(&w.bytes,u8(value>>uint(i*8)))}}
@(private="file") u64_put :: proc(w:^Writer,value:u64) {u32_put(w,u32(value));u32_put(w,u32(value>>32))}
@(private="file") name_put :: proc(w:^Writer,name:string) {u32_put(w,name_index(name));u32_put(w,0)}
@(private="file") text_put :: proc(w:^Writer,text:string) {u32_put(w,u32(len(text)+1));append(&w.bytes,..transmute([]u8)text);append(&w.bytes,0)}
@(private="file") u32_patch :: proc(w:^Writer,at:int,value:u32) {endian.put_u32(w.bytes[at:],.Little,value)}

@(private="file")
tag_put :: proc(w:^Writer,name,type:string,size:int,extra:string="") {
    name_put(w,name)
    name_put(w,type)
    u32_put(w,u32(size))
    u32_put(w,0)
    if type=="StructProperty" {name_put(w,extra);for _ in 0..<16 {append(&w.bytes,0)}}
    if type=="ByteProperty" {name_put(w,extra)}
    if type=="BoolProperty" {append(&w.bytes,1 if extra=="true" else 0)}
    append(&w.bytes,0)
}

@(private="file")
Fixture :: struct {width,height:int,format,compression,settings:string,srgb:bool,pixels:[]u8,class:string,slices:int}

@(private="file")
texture_package :: proc(f:Fixture) -> []u8 {
    w:Writer
    w.bytes.allocator=context.temp_allocator
    u32_put(&w,0x9e2a83c1)
    u32_put(&w,transmute(u32)i32(-7))
    u32_put(&w,864);u32_put(&w,522);u32_put(&w,0)
    u32_put(&w,0) // custom versions
    header_at:=len(w.bytes);u32_put(&w,0)
    text_put(&w,"/Game/T_Test")
    u32_put(&w,0) // flags
    names:=NAMES
    u32_put(&w,u32(len(names)));name_at:=len(w.bytes);u32_put(&w,0)
    text_put(&w,"")
    u64_put(&w,0)
    u32_put(&w,1);export_at:=len(w.bytes);u32_put(&w,0)
    u32_put(&w,2);import_at:=len(w.bytes);u32_put(&w,0)
    u32_put(&w,0);u64_put(&w,0);u32_put(&w,0);u32_put(&w,0)
    for _ in 0..<32 {append(&w.bytes,0)}
    u32_put(&w,0) // generations
    for _ in 0..<2 {for _ in 0..<10 {append(&w.bytes,0)};text_put(&w,"")}
    u32_put(&w,0);u32_put(&w,0);u32_put(&w,0);u32_put(&w,0)
    u32_put(&w,0);bulk_at:=len(w.bytes);u64_put(&w,0);u32_put(&w,0)
    u32_put(&w,0);u64_put(&w,0)
    u32_patch(&w,name_at,u32(len(w.bytes)))
    for name in names {text_put(&w,name);u32_put(&w,0)}
    u32_patch(&w,import_at,u32(len(w.bytes)))
    name_put(&w,"/Script/Engine");name_put(&w,"Package");u32_put(&w,0);name_put(&w,"/Script/Engine");name_put(&w,"None")
    name_put(&w,"/Script/Engine");name_put(&w,"Class");u32_put(&w,transmute(u32)i32(-1));name_put(&w,f.class if f.class!="" else "Texture2D");name_put(&w,"None")
    u32_patch(&w,export_at,u32(len(w.bytes)))
    u32_put(&w,transmute(u32)i32(-2));u32_put(&w,0);u32_put(&w,0);u32_put(&w,0);name_put(&w,"T_Test");u32_put(&w,0)
    size_at:=len(w.bytes);u64_put(&w,0);u64_put(&w,0)
    for _ in 0..<12 {append(&w.bytes,0)}
    for _ in 0..<16 {append(&w.bytes,0)}
    u32_put(&w,0);u32_put(&w,0);u32_put(&w,1)
    for _ in 0..<20 {append(&w.bytes,0)}
    u32_patch(&w,header_at,u32(len(w.bytes)))
    data_at:=len(w.bytes)
    source:Writer
    source.bytes.allocator=context.temp_allocator
    for field in ([4]string{"SizeX","SizeY","NumSlices","NumMips"}) {
        tag_put(&source,field,"IntProperty",4)
        value:=f.width if field=="SizeX" else f.height if field=="SizeY" else max(f.slices,1) if field=="NumSlices" else 1
        u32_put(&source,u32(value))
    }
    tag_put(&source,"Format","ByteProperty",8,"ETextureSourceFormat");name_put(&source,f.format)
    tag_put(&source,"CompressionFormat","ByteProperty",8,"ETextureSourceCompressionFormat");name_put(&source,f.compression)
    name_put(&source,"None")
    tag_put(&w,"Source","StructProperty",len(source.bytes),"TextureSource")
    append(&w.bytes,..source.bytes[:])
    tag_put(&w,"CompressionSettings","ByteProperty",8,"TextureCompressionSettings");name_put(&w,f.settings)
    tag_put(&w,"SRGB","BoolProperty",0,"true" if f.srgb else "false")
    name_put(&w,"None")
    u32_put(&w,0)                 // no lazy guid
    append(&w.bytes,0,0)          // strip flags
    u32_put(&w,0);u32_put(&w,u32(len(f.pixels)));u32_put(&w,u32(len(f.pixels)))
    u64_put(&w,u64(len(w.bytes)+8))
    append(&w.bytes,..f.pixels)
    endian.put_u64(w.bytes[size_at:],.Little,u64(len(w.bytes)-data_at))
    endian.put_u64(w.bytes[size_at+8:],.Little,u64(data_at))
    endian.put_u64(w.bytes[bulk_at:],.Little,u64(len(w.bytes)))
    return w.bytes[:]
}

@(private="file")
open_and_decode :: proc(t:^testing.T,bytes:[]u8,loc:=#caller_location) -> (source:Texture,decoded:Decoded,ok:bool) {
    p,error:=unreal.package_open(bytes)
    if !testing.expect_value(t,error.code,unreal.Error_Code.None,loc=loc) {return}
    defer unreal.package_destroy(&p)
    source,error=texture_read(&p,0)
    if !testing.expect_value(t,error.code,unreal.Error_Code.None,loc=loc) {return}
    decoder,_:=kraken.decoder_make(context.temp_allocator)
    decoded,error=texture_decode(&p,&source,&decoder)
    if !testing.expect_value(t,error.code,unreal.Error_Code.None,loc=loc) {texture_destroy(&source);return}
    return source,decoded,true
}

@(test)
texture_sources_decode_to_rgba_in_mirai_conventions :: proc(t:^testing.T) {
    bgra:=[]u8{10,20,30,40, 50,60,70,80, 90,100,110,120, 130,140,150,160}
    source,decoded,ok:=open_and_decode(t,texture_package({2,2,"TSF_BGRA8","TSCF_None","TC_Default",true,bgra,"",0}))
    if !ok {return}
    testing.expect_value(t,source.usage,Usage.Color)
    testing.expect_value(t,decoded.format,Pixel_Format.RGBA8)
    testing.expect_value(t,[4]u8{decoded.pixels[0],decoded.pixels[1],decoded.pixels[2],decoded.pixels[3]},[4]u8{30,20,10,40})
    input,_:=texture_build_input(&source,&decoded)
    testing.expect(t,input.options.srgb && !input.options.normal_map && input.approximations=={})
    build_input_destroy(&input)
    decoded_destroy(&decoded)
    texture_destroy(&source)

    // Normal maps leave with +Y: green inverted, linear, built as normals.
    source,decoded,ok=open_and_decode(t,texture_package({2,2,"TSF_BGRA8","TSCF_None","TC_Normalmap",false,bgra,"",0}))
    if !ok {return}
    testing.expect_value(t,source.usage,Usage.Normal)
    testing.expect_value(t,[4]u8{decoded.pixels[0],decoded.pixels[1],decoded.pixels[2],decoded.pixels[3]},[4]u8{30,255-20,10,40})
    input,_=texture_build_input(&source,&decoded)
    testing.expect(t,!input.options.srgb && input.options.normal_map)
    build_input_destroy(&input)
    decoded_destroy(&decoded)
    texture_destroy(&source)

    // 16 bit sources stay 16 bit, and so does what a .tex is built from.
    rgba16:=make([]u8,2*2*8,context.temp_allocator)
    for i in 0..<16 {endian.put_u16(rgba16[i*2:],.Little,u16(i*4000))}
    source,decoded,ok=open_and_decode(t,texture_package({2,2,"TSF_RGBA16","TSCF_None","TC_Masks",true,rgba16,"",0}))
    if !ok {return}
    testing.expect_value(t,source.usage,Usage.Data)
    testing.expect_value(t,decoded.format,Pixel_Format.RGBA16)
    input,_=texture_build_input(&source,&decoded)
    testing.expect(t,input.source.format==.RGBA16 && string(input.source.texels)==string(rgba16) && input.approximations=={} && !input.options.keep_precision)
    build_input_destroy(&input)
    decoded_destroy(&decoded)
    texture_destroy(&source)

    // A grayscale of 16 bits keeps its precision in the .tex.
    source,decoded,ok=open_and_decode(t,texture_package({2,2,"TSF_RGBA16","TSCF_None","TC_Grayscale",false,rgba16,"",0}))
    if !ok {return}
    input,_=texture_build_input(&source,&decoded)
    testing.expect(t,input.options.keep_precision)
    build_input_destroy(&input)
    decoded_destroy(&decoded)
    texture_destroy(&source)
}

// A cube of six faces of 2x2, each the color of its index in Unreal's order.
@(private="file")
unreal_faces :: proc() -> []u8 {
    faces:=make([]u8,6*2*2*4,context.temp_allocator)
    for face in 0..<6 {
        for texel in 0..<4 {
            at:=(face*4+texel)*4
            faces[at],faces[at+1],faces[at+2],faces[at+3]=u8(texel*10),u8(texel),u8(face*40),255 // BGRA: red is the face
        }
    }
    return faces
}

@(test)
cubes_and_arrays_keep_their_slices_with_the_axes_of_mirai :: proc(t:^testing.T) {
    source,decoded,ok:=open_and_decode(t,texture_package({2,2,"TSF_BGRA8","TSCF_None","TC_Default",true,unreal_faces(),"TextureCube",6}))
    if !ok {return}
    testing.expect(t,source.kind==.Cube && !source.long_lat)
    input,_:=texture_build_input(&source,&decoded)
    testing.expect(t,input.source.cube && input.source.layers==6 && input.source.format==.RGBA8 && input.approximations=={})
    // Mirai's +X is Unreal's +Y, its -X Unreal's -Y, its +Y Unreal's +Z and its +Z Unreal's -X.
    unreal_face:=[6]int{2,3,4,5,1,0}
    for face,layer in unreal_face {
        for texel in 0..<4 {testing.expectf(t,input.source.texels[(layer*4+texel)*4]==u8(face*40),"face %d of Mirai is face %d of Unreal",layer,face)}
    }
    // A texel at the center of a face direction lands on the texel of the same direction.
    for face in 0..<6 {
        for texel in 0..<4 {
            got,x,y:=cube_texel(cube_direction(face,texel%2,texel/2,2),2)
            testing.expect(t,got==face && x==texel%2 && y==texel/2)
        }
    }
    // Its sky: the zenith (Unreal's +Z) on the top row, the nadir on the bottom one, and across
    // the middle rows -X, -Z, +X and +Z of Mirai (Unreal's -Y, +X, +Y and -X).
    sky,sky_error:=sky_of_cube(input.source,true,context.temp_allocator)
    if !testing.expect(t,sky_error.code==.None && sky.width==8 && sky.height==4 && sky.layers==1 && !sky.cube) {return}
    red :: proc(sky:textures.Source,column,row:int) -> int {return int(sky.texels[(row*sky.width+column)*4])}
    for column in 0..<8 {
        testing.expectf(t,abs(red(sky,column,0)-4*40)<=1 && abs(red(sky,column,3)-5*40)<=1,"column %d: top %d, bottom %d",column,red(sky,column,0),red(sky,column,3))
    }
    for face,column in ([4]int{3,0,2,1}) {
        for row in 1..=2 {testing.expectf(t,abs(red(sky,2*column,row)-face*40)<=1,"column %d row %d is face %d of Unreal: %d",2*column,row,face,red(sky,2*column,row))}
    }
    _,cube_error:=sky_of_cube({width=2,height=2,layers=1,format=.RGBA8,texels=make([]u8,16,context.temp_allocator)},true)
    testing.expect(t,cube_error.code!=.None,"an image that is not a cube has no sky")
    build_input_destroy(&input)
    decoded_destroy(&decoded)
    texture_destroy(&source)

    source,decoded,ok=open_and_decode(t,texture_package({2,2,"TSF_BGRA8","TSCF_None","TC_Masks",false,unreal_faces()[:3*16],"Texture2DArray",3}))
    if !ok {return}
    input,_=texture_build_input(&source,&decoded)
    testing.expect(t,source.kind==.Array && !input.source.cube && input.source.layers==3 && input.source.texels[2*16]==2*40)
    build_input_destroy(&input)
    decoded_destroy(&decoded)
    texture_destroy(&source)
}

@(test)
an_hdr_long_lat_cube_keeps_its_light :: proc(t:^testing.T) {
    // 8x4 texels of RGBE: blue about 100 and red 0.25 below the top row, red about 2000 on it.
    rgbe:=make([]u8,8*4*4,context.temp_allocator)
    for texel in 0..<32 {
        at:=texel*4
        rgbe[at],rgbe[at+1],rgbe[at+2],rgbe[at+3]=200,128,texel<8?250:0,texel<8?139:135
    }
    source,decoded,ok:=open_and_decode(t,texture_package({8,4,"TSF_BGRE8","TSCF_None","TC_HDR",false,rgbe,"TextureCube",1}))
    if !ok {return}
    testing.expect(t,source.kind==.Cube && source.long_lat && source.usage==.Data)
    input,_:=texture_build_input(&source,&decoded)
    testing.expect(t,input.source.cube && input.source.layers==6 && input.source.width==LONG_LAT_SMALLEST_FACE && input.source.format==.RGBA32F && input.approximations=={})
    linear:=textures.transfer_make(false)
    size:=input.source.width
    brightest:=f32(0)
    for at in 0..<size*size*6 {
        value:=textures.texel_read(input.source.texels,input.source.format,at,&linear)
        brightest=max(brightest,value.r)
        testing.expect(t,value.b>=(200+0.5)*0.5-0.01,"blue is above 1 everywhere")
    }
    testing.expectf(t,brightest>1000,"the top row above the pole of +Y keeps its light: %v",brightest)
    // The texel of Mirai's up (+Y, the third face) looks at Unreal's +Z: the top row.
    up:=textures.texel_read(input.source.texels,input.source.format,2*size*size+size/2*size+size/2,&linear)
    testing.expectf(t,up.r>1000,"up is the top row: %v",up)
    build_input_destroy(&input)
    decoded_destroy(&decoded)
    texture_destroy(&source)
}

// The forward row delta, bottom up so each row still sees the original above it.
@(private="file")
delta_forward_tile :: proc(surface:[]u8,stride,x,width,y,rows,element:int) {
    for row:=y+rows-1;row>y;row-=1 {
        for i:=0;i<width;i+=element {
            at,above:=row*stride+x+i,(row-1)*stride+x+i
            switch element {
            case 1:surface[at]-=surface[above]
            case 2:
                a,_:=endian.get_u16(surface[at:],.Little)
                b,_:=endian.get_u16(surface[above:],.Little)
                endian.put_u16(surface[at:],.Little,a-b+0x8080)
            case 4:
                a,_:=endian.get_u32(surface[at:],.Little)
                b,_:=endian.get_u32(surface[above:],.Little)
                endian.put_u32(surface[at:],.Little,a-b+0x80808080)
            }
        }
    }
}

@(private="file")
delta_forward :: proc(surface:[]u8,width,height,pixel,element:int) {
    stride:=width*pixel
    cuts :: proc(width,height:int) -> (count,rows:int) {
        first:=1
        if width*height>32768 {first=width*height/32768;for first>512 {first>>=1}}
        rows=(height+first-1)/first
        return (height+rows-1)/rows,rows
    }
    if width*height<=136*136 {delta_forward_tile(surface,stride,0,stride,0,height,element);return}
    if stride<=4096 {
        count,rows:=cuts(width,height)
        for c in 0..<count {delta_forward_tile(surface,stride,0,stride,c*rows,min(rows,height-c*rows),element)}
        return
    }
    parts:=(stride+4095)/4096
    part_bytes:=((stride+parts/2)/parts+63)&~int(63)
    part:=part_bytes/pixel
    parts=(width+part-1)/part
    for p in 0..<parts {
        x:=p*part
        strip:=min(part,width-x)
        count,rows:=cuts(strip,height)
        for c in 0..<count {delta_forward_tile(surface,stride,x*pixel,strip*pixel,c*rows,min(rows,height-c*rows),element)}
    }
}

@(test)
texture_ue_delta_sources_are_restored_in_tiles :: proc(t:^testing.T) {
    // Sizes that keep one tile, cut rows, and cut columns of a wide surface.
    for size in ([3][2]int{{20,10},{300,300},{1100,40}}) {
        for element in ([3]int{1,2,4}) {
            pixel:=2 if element==2 else 4
            original:=make([]u8,size[0]*size[1]*pixel,context.temp_allocator)
            state:=u32(size[0]*31+element)
            for &value,i in original {state=state*1664525+1013904223;value=u8(state>>24) if i%5==0 else u8(i/pixel)}
            stored:=make([]u8,len(original),context.temp_allocator)
            copy(stored,original)
            delta_forward(stored,size[0],size[1],pixel,element)
            delta_inverse_surface(stored,size[0],size[1],pixel,element)
            testing.expectf(t,string(stored)==string(original),"%v with %d byte elements",size,element)
        }
    }
    pixels:=make([]u8,300*300*4,context.temp_allocator)
    for &value,i in pixels {value=u8(i*7)}
    stored:=make([]u8,len(pixels),context.temp_allocator)
    copy(stored,pixels)
    delta_forward(stored,300,300,4,1)
    source,decoded,ok:=open_and_decode(t,texture_package({300,300,"TSF_BGRA8","TSCF_UEDELTA","TC_Masks",false,stored,"",0}))
    if !ok {return}
    for i in 0..<300*300 {
        if decoded.pixels[i*4]!=pixels[i*4+2] || decoded.pixels[i*4+2]!=pixels[i*4] {testing.expect(t,false,"UEDELTA pixels");break}
    }
    decoded_destroy(&decoded)
    texture_destroy(&source)
}

// A damaged texture package is decoded or refused, never a crash.
@(test)
texture_damaged_packages_are_decoded_or_refused :: proc(t:^testing.T) {
    pixels:=make([]u8,8*8*4,context.temp_allocator)
    for &value,i in pixels {value=u8(i)}
    bytes:=texture_package({8,8,"TSF_BGRA8","TSCF_None","TC_Default",true,pixels,"",0})
    decoder,_:=kraken.decoder_make(context.temp_allocator)
    attempt :: proc(bytes:[]u8,decoder:^kraken.Decoder) -> bool {
        p,error:=unreal.package_open(bytes)
        if error.code!=.None {return false}
        defer unreal.package_destroy(&p)
        source:Texture
        source,error=texture_read(&p,0)
        if error.code!=.None {return false}
        defer texture_destroy(&source)
        decoded:Decoded
        decoded,error=texture_decode(&p,&source,decoder)
        if error.code!=.None {return false}
        input,input_error:=texture_build_input(&source,&decoded)
        build_input_destroy(&input)
        decoded_destroy(&decoded)
        return input_error.code==.None
    }
    testing.expect(t,attempt(bytes,&decoder))
    refused:=0
    for length in 0..<len(bytes) {if !attempt(bytes[:length],&decoder) {refused+=1}}
    damaged:=make([]u8,len(bytes),context.temp_allocator)
    for position in 0..<len(bytes) {
        for value in ([3]u8{0,0xff,bytes[position]+1}) {
            copy(damaged,bytes)
            damaged[position]=value
            if !attempt(damaged,&decoder) {refused+=1}
        }
    }
    testing.expect(t,refused>0)
}

// A UE JPEG payload laid out as Unreal's encoder writes it: magic, IHDR, LHDR
// with quantization steps of 1, and one SPLT chunk per split. Split s holds,
// per component, the block rows [s*n,(s+1)*n) with n=ceil(shortest/splits)*
// rows/shortest; inside, coefficient e of every block of the component in a
// row, each plus 0x80, the low bytes of the split before its high bytes. An
// Oodle split is a Kraken stream of one stored block.
@(private="file")
Uejpeg :: struct {
    width,height,components,splits:int,
    oodle:bool,
    blocks:[4][2]int,
    transform:i8,
    ids:[4]u8,
    coefficient:proc(component,x,y,e:int) -> i16, // e in stored order: 0 is DC
}

@(private="file")
uejpeg_payload :: proc(u:Uejpeg) -> []u8 {
    w:Writer
    w.bytes.allocator=context.temp_allocator
    append(&w.bytes,..transmute([]u8)string("OOJPEG"))
    u32_put(&w,16);append(&w.bytes,..transmute([]u8)string("IHDR"))
    u32_put(&w,4);u32_put(&w,u32(u.width));u32_put(&w,u32(u.height))
    append(&w.bytes,8,u8(u.components),0x0D if u.oodle else 0,u8(u.splits))
    u32_put(&w,534);append(&w.bytes,..transmute([]u8)string("LHDR"))
    for c in 0..<4 {for d in 0..<2 {u16_put(&w,u16(u.blocks[c][d]))}}
    for _ in 0..<4*64 {u16_put(&w,1)}
    append(&w.bytes,transmute(u8)u.transform,0)
    ids:=u.ids
    append(&w.bytes,..ids[:])
    shortest:=max(int)
    for c in 0..<u.components {shortest=min(shortest,u.blocks[c][1])}
    share:=(shortest+u.splits-1)/u.splits
    for s in 0..<u.splits {
        values:[dynamic]i16
        values.allocator=context.temp_allocator
        for c in 0..<u.components {
            rows:=u.blocks[c][1]/shortest*share
            start,end:=min(rows*s,u.blocks[c][1]),min(rows*(s+1),u.blocks[c][1])
            for e in 0..<64 {for y in start..<end {for x in 0..<u.blocks[c][0] {append(&values,u.coefficient(c,x,y,e)+0x80)}}}
        }
        chunk:[dynamic]u8
        chunk.allocator=context.temp_allocator
        if u.oodle && len(values)>0 {append(&chunk,0x4C,0x06)}
        for value in values {append(&chunk,u8(value))}
        for value in values {append(&chunk,u8(u16(value)>>8))}
        u32_put(&w,u32(len(chunk)));append(&w.bytes,..transmute([]u8)string("SPLT"))
        append(&w.bytes,..chunk[:])
    }
    return w.bytes[:]
}

// With steps of 1 a DC of 8*v alone makes every sample of its block 128+v.
@(private="file")
uejpeg_dc :: proc(v:int) -> i16 {return i16(8*v)}

// 13x29 YCbCr and alpha, 4:2:0, in two Oodle splits: each luma block has its
// own gray, each alpha block row its own alpha; chroma is neutral.
@(private="file")
uejpeg_ycbcra :: proc() -> []u8 {
    return uejpeg_payload({13,29,4,2,true,{{2,4},{1,2},{1,2},{2,4}},1,{1,2,3,4},proc(c,x,y,e:int) -> i16 {
        if e!=0 || c==1 || c==2 {return 0}
        return uejpeg_dc(x*20+y*10-40) if c==0 else uejpeg_dc(y*25)
    }})
}

// One gray 8x8 block with AC coefficients.
@(private="file")
uejpeg_block :: proc() -> []u8 {
    return uejpeg_payload({8,8,1,1,false,{{1,1},{},{},{}},-1,{1,0,0,0},proc(c,x,y,e:int) -> i16 {
        switch e {
        case 0:return 40
        case 1:return -30
        case 2:return 25
        case 4:return 12
        case 9:return -7
        case 35:return 3
        }
        return 0
    }})
}

// 13x8 YCbCr without subsampling, one color: the first 8 pixels go through
// the SSE2 conversion and the last 5 through the scalar one. With the
// component ids R, G and B the components are the color.
@(private="file")
uejpeg_color :: proc(ids:[4]u8) -> []u8 {
    return uejpeg_payload({13,8,3,1,false,{{2,1},{2,1},{2,1},{}},-1,ids,proc(c,x,y,e:int) -> i16 {
        if e!=0 {return 0}
        values:=[3]int{0,-20,25}
        return uejpeg_dc(values[c])
    }})
}

@(test)
texture_ue_jpeg_sources_decode_as_unreal_does :: proc(t:^testing.T) {
    decoder,_:=kraken.decoder_make(context.temp_allocator)
    // The samples Unreal's x64 decoder gives for the block.
    block:=[64]u8{
        130,122,134,133,129,139,140,136, 129,122,133,133,128,138,140,135,
        129,123,132,133,128,137,140,135, 129,124,132,134,129,137,142,136,
        128,125,131,135,130,136,143,135, 127,126,129,134,130,134,143,134,
        127,126,128,135,130,133,144,134, 128,128,129,135,131,133,145,134,
    }
    rgba,error:=uejpeg_decode(uejpeg_block(),8,8,&decoder)
    if testing.expect_value(t,error.code,unreal.Error_Code.None) {
        for i in 0..<64 {
            if ([4]u8{rgba[i*4],rgba[i*4+1],rgba[i*4+2],rgba[i*4+3]}!=[4]u8{block[i],block[i],block[i],255}) {testing.expectf(t,false,"block sample %d",i);break}
        }
        delete(rgba)
    }
    for ids,rgb in ([2][4]u8{{1,2,3,0},{'R','G','B',0}}) {
        rgba,error=uejpeg_decode(uejpeg_color(ids),13,8,&decoder)
        if !testing.expect_value(t,error.code,unreal.Error_Code.None) {continue}
        want:=[4]u8{128,108,153,255} if rgb==1 else [4]u8{163,117,93,255}
        for i in 0..<13*8 {
            if ([4]u8{rgba[i*4],rgba[i*4+1],rgba[i*4+2],rgba[i*4+3]}!=want) {testing.expectf(t,false,"color pixel %d",i);break}
        }
        delete(rgba)
    }

    // Through a package: a BGRA8 source leaves as RGBA rows from the top, from both splits.
    source,decoded,ok:=open_and_decode(t,texture_package({13,29,"TSF_BGRA8","TSCF_UEJPEG","TC_Default",true,uejpeg_ycbcra(),"",0}))
    if !ok {return}
    testing.expect_value(t,source.compression,Source_Compression.UEJPEG)
    testing.expect_value(t,decoded.format,Pixel_Format.RGBA8)
    loop: for y in 0..<29 {
        for x in 0..<13 {
            gray,alpha:=u8(88+x/8*20+y/8*10),u8(128+y/8*25)
            at:=(y*13+x)*4
            if ([4]u8{decoded.pixels[at],decoded.pixels[at+1],decoded.pixels[at+2],decoded.pixels[at+3]}!=[4]u8{gray,gray,gray,alpha}) {
                testing.expectf(t,false,"pixel %d,%d",x,y)
                break loop
            }
        }
    }
    decoded_destroy(&decoded)
    texture_destroy(&source)

    // A G8 source keeps red.
    source,decoded,ok=open_and_decode(t,texture_package({8,8,"TSF_G8","TSCF_UEJPEG","TC_Masks",false,uejpeg_block(),"",0}))
    if !ok {return}
    testing.expect_value(t,decoded.pixels[5*4],block[5])
    decoded_destroy(&decoded)
    texture_destroy(&source)
}

// A damaged UE JPEG source is decoded or refused, never a crash, and the
// damage that would make Unreal read outside its planes is refused.
@(test)
texture_ue_jpeg_damage_is_decoded_or_refused :: proc(t:^testing.T) {
    decoder,_:=kraken.decoder_make(context.temp_allocator)
    IHDR :: 14
    LHDR :: 38
    SPLITS :: 572
    patched :: proc(bytes:[]u8,at:int,values:..u8) -> []u8 {
        out:=make([]u8,len(bytes),context.temp_allocator)
        copy(out,bytes)
        copy(out[at:],values)
        return out
    }
    expect_refused :: proc(t:^testing.T,bytes:[]u8,width,height:int,code:unreal.Error_Code,decoder:^kraken.Decoder,loc:=#caller_location) {
        rgba,error:=uejpeg_decode(bytes,width,height,decoder)
        delete(rgba)
        testing.expect_value(t,error.code,code,loc=loc)
    }
    block,ycbcra:=uejpeg_block(),uejpeg_ycbcra()
    expect_refused(t,patched(block,0,'X'),8,8,.Malformed,&decoder)
    expect_refused(t,patched(block,IHDR,5),8,8,.Unsupported_Value,&decoder)
    expect_refused(t,block,8,9,.Malformed,&decoder)
    expect_refused(t,patched(block,LHDR+2,3),8,8,.Malformed,&decoder)          // block rows past the image
    expect_refused(t,patched(block,SPLITS,127),8,8,.Malformed,&decoder)        // stored split of another size
    expect_refused(t,patched(ycbcra,SPLITS,0,0,0,0),13,29,.Malformed,&decoder) // empty Oodle split
    expect_refused(t,patched(ycbcra,SPLITS+8,0x0C),13,29,.Malformed,&decoder)  // Kraken block no longer stored
    subsampled:=uejpeg_payload({32,8,3,1,false,{{4,1},{1,1},{1,1},{}},-1,{1,2,3,0},proc(c,x,y,e:int) -> i16 {return 0}})
    expect_refused(t,subsampled,32,8,.Unsupported_Value,&decoder)              // chroma at a quarter
    p,_:=unreal.package_open(texture_package({8,8,"TSF_RGBA16F","TSCF_UEJPEG","TC_Default",false,block,"",0}))
    source,_:=texture_read(&p,0)
    _,error:=texture_decode(&p,&source,&decoder)
    testing.expect_value(t,error.code,unreal.Error_Code.Unsupported_Value)
    texture_destroy(&source)
    unreal.package_destroy(&p)

    bytes:=texture_package({13,29,"TSF_BGRA8","TSCF_UEJPEG","TC_Default",true,ycbcra,"",0})
    attempt :: proc(bytes:[]u8,decoder:^kraken.Decoder) -> bool {
        p,error:=unreal.package_open(bytes)
        if error.code!=.None {return false}
        defer unreal.package_destroy(&p)
        source:Texture
        source,error=texture_read(&p,0)
        if error.code!=.None {return false}
        defer texture_destroy(&source)
        decoded:Decoded
        decoded,error=texture_decode(&p,&source,decoder)
        decoded_destroy(&decoded)
        return error.code==.None
    }
    testing.expect(t,attempt(bytes,&decoder))
    damaged:=make([]u8,len(bytes),context.temp_allocator)
    for position in 0..<len(bytes) {
        _=attempt(bytes[:position],&decoder)
        for value in ([3]u8{0,0xff,bytes[position]+1}) {
            copy(damaged,bytes)
            damaged[position]=value
            _=attempt(damaged,&decoder)
        }
    }
}

@(test)
texture_halves_convert_exactly :: proc(t:^testing.T) {
    for bits in 0..<0x10000 {
        expected:=f32(transmute(f16)u16(bits))
        got:=half_to_f32(u16(bits))
        if transmute(u32)expected!=transmute(u32)got {
            testing.expectf(t,false,"half 0x%4x gives 0x%8x, not 0x%8x",bits,transmute(u32)got,transmute(u32)expected)
            break
        }
    }
}
