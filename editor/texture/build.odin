package unreal_texture

import "core:math"
import "core:mem"
import "mirai:asset"
import "mirai:cook/textures"
import unreal "project:plugins/unreal/editor/package"

@(private="file")
FACES :: asset.TEXTURE_CUBE_FACES

// What a .tex does not keep of a source; an import reports each one.
Approximation :: enum u8 {
    Slices_Dropped, // the depth of a volume after its first slice
    Layers_Dropped, // the layers of a source after the first
    Blocks_Dropped, // UDIM tiles after the first
    Mips_Rebuilt,   // authored mips replaced by the chain cook/textures builds
}
Approximations :: bit_set[Approximation;u8]

// The texels and options cook/textures.build takes to write a .tex.
Build_Input :: struct {
    source:textures.Source, // owns its texels
    options:textures.Build_Options,
    approximations:Approximations,
}

build_input_destroy :: proc(input:^Build_Input) {
    if input==nil {return}
    textures.source_destroy(&input.source)
    input^={}
}

// Level 0 of the first block and layer, with its precision: 8 bits as sRGB
// for color (the 2.2 curve of legacy_gamma brought to it) and linear for
// data and normals, 16 bits the same way, and floats as they are. An array
// keeps its slices, and a cube its faces in Mirai's order and axes
// (cube_faces), from six slices per cube or from longitude-latitude images
// (cube_long_lat). A volume keeps its first slice.
texture_build_input :: proc(texture:^Texture,decoded:^Decoded,allocator:=context.allocator) -> (input:Build_Input,error:unreal.Error) {
    if texture==nil || decoded==nil || len(decoded.levels)==0 || len(texture.blocks)==0 {return {},{.Invalid_Reference,0,"decoded texture"}}
    level:=decoded.levels[0]
    color:=texture.usage==.Color
    input.options={srgb=color,normal_map=texture.usage==.Normal,keep_precision=texture.keep_precision}
    if len(texture.layers)>1 {input.approximations+={.Layers_Dropped}}
    if len(texture.blocks)>1 {input.approximations+={.Blocks_Dropped}}
    if texture.blocks[0].mips>1 {input.approximations+={.Mips_Rebuilt}}
    format:textures.Source_Format
    switch decoded.format {
    case .RGBA8: format=.RGBA8
    case .RGBA16: format=.RGBA16
    case .RGBA32F: format=.RGBA32F
    }
    slices:=level.slices
    if texture.kind==.Volume && slices>1 {
        input.approximations+={.Slices_Dropped}
        slices=1
    }
    from:=textures.Source{texels=decoded.pixels[level.offset:][:level.width*level.height*slices*pixel_bytes(decoded.format)],width=level.width,height=level.height,layers=slices,format=format}
    // Decoded 16 bits are linear: color takes the sRGB curve, as 8 bits have it.
    read:=textures.transfer_make(false)
    stored:=textures.transfer_make(color && format!=.RGBA32F)
    if color && format==.RGBA8 {
        if texture.legacy_gamma {
            for &value in read.table {value=math.pow(value,2.2)}
        } else {
            read=stored
        }
    }
    cube:=texture.kind==.Cube || texture.kind==.Cube_Array
    switch {
    case cube && texture.long_lat:
        input.source,error=cube_long_lat(from,&read,&stored,allocator)
    case cube && slices%FACES==0:
        input.source,error=cube_faces(from,&read,&stored,allocator)
    case:
        input.source,error=source_copy(from,&read,&stored,allocator)
    }
    if error.code!=.None {return {},error}
    return
}

// The texels of from, read with one transfer and written with another.
@(private="file")
source_copy :: proc(from:textures.Source,read,stored:^textures.Transfer,allocator:mem.Allocator) -> (source:textures.Source,error:unreal.Error) {
    source=from
    source.allocator=allocator
    allocation_error:mem.Allocator_Error
    if source.texels,allocation_error=make([]u8,len(from.texels),allocator);allocation_error!=nil {return {},{.Out_Of_Memory,0,"texture build texels"}}
    if read.srgb==stored.srgb && read.table==stored.table {
        copy(source.texels,from.texels)
        return
    }
    for at in 0..<from.width*from.height*max(from.layers,1) {textures.texel_write(source.texels,from.format,at,textures.texel_read(from.texels,from.format,at,read),stored)}
    return
}

// The direction of the center of texel (x,y) of a face of a cube of side
// size, faces +X, -X, +Y, -Y, +Z, -Z, as GPUs sample a cube and Unreal
// writes it (TransformSideToWorldSpace).
@(private)
cube_direction :: proc "contextless" (face,x,y,size:int) -> [3]f32 {
    u:=(f32(x)+0.5)/f32(size)*2-1
    v:=(f32(y)+0.5)/f32(size)*2-1
    switch face {
    case 0: return {1,-v,-u}
    case 1: return {-1,-v,u}
    case 2: return {u,1,v}
    case 3: return {u,-1,-v}
    case 4: return {u,-v,1}
    }
    return {-u,-v,-1}
}

// The face of a cube a direction lands on, and where on it, -1 to 1 across
// its texels.
@(private)
cube_face :: proc "contextless" (d:[3]f32) -> (face:int,u,v:f32) {
    a:=[3]f32{abs(d.x),abs(d.y),abs(d.z)}
    switch {
    case a.x>=a.y && a.x>=a.z:
        face=0 if d.x>0 else 1
        u,v=(-d.z if d.x>0 else d.z)/a.x,-d.y/a.x
    case a.y>=a.z:
        face=2 if d.y>0 else 3
        u,v=d.x/a.y,(d.z if d.y>0 else -d.z)/a.y
    case:
        face=4 if d.z>0 else 5
        u,v=(d.x if d.z>0 else -d.x)/a.z,-d.y/a.z
    }
    return
}

// The face of a cube and the texel of it a direction lands on.
@(private)
cube_texel :: proc "contextless" (d:[3]f32,size:int) -> (face,x,y:int) {
    u,v:f32
    face,u,v=cube_face(d)
    x=clamp(int(math.floor((u+1)*0.5*f32(size))),0,size-1)
    y=clamp(int(math.floor((v+1)*0.5*f32(size))),0,size-1)
    return
}

// Unreal's world direction of one of Mirai (the inverse of level.SPACE: +X
// is Unreal's +Y, +Y its +Z and -Z its +X).
@(private)
unreal_direction :: proc "contextless" (m:[3]f32) -> [3]f32 {return {-m.z,m.x,m.y}}

// Faces whose texel sampled with a direction of Mirai's world is the one
// Unreal samples with the same direction of its world: each texel of a face
// of Mirai is a texel of a face of Unreal, turned or mirrored.
@(private="file")
cube_faces :: proc(from:textures.Source,read,stored:^textures.Transfer,allocator:mem.Allocator) -> (source:textures.Source,error:unreal.Error) {
    if from.width!=from.height {return {},{.Unsupported_Value,0,"the faces of a cube are not square"}}
    unreal_faces:textures.Source
    if unreal_faces,error=source_copy(from,read,stored,allocator);error.code!=.None {return}
    defer textures.source_destroy(&unreal_faces)
    source=unreal_faces
    source.cube,source.allocator=true,allocator
    allocation_error:mem.Allocator_Error
    if source.texels,allocation_error=make([]u8,len(from.texels),allocator);allocation_error!=nil {return {},{.Out_Of_Memory,0,"cube faces"}}
    size:=from.width
    bytes:=len(from.texels)/(size*size*from.layers)
    for layer in 0..<from.layers {
        cube:=layer/FACES*FACES
        for y in 0..<size {
            for x in 0..<size {
                face,fx,fy:=cube_texel(unreal_direction(cube_direction(layer%FACES,x,y,size)),size)
                copy(source.texels[((layer*size+y)*size+x)*bytes:][:bytes],unreal_faces.texels[((cube+face)*size*size+fy*size+fx)*bytes:][:bytes])
            }
        }
    }
    return
}

// The side of the faces of a cube made from a longitude-latitude image of a
// width: the power of two of half of it or below, at least
// LONG_LAT_SMALLEST_FACE.
LONG_LAT_SMALLEST_FACE :: 32

long_lat_face :: proc "contextless" (width:int) -> int {
    face:=1
    for face*2<=width/2 {face*=2}
    return max(face,LONG_LAT_SMALLEST_FACE)
}

// The six faces of a cube from each longitude-latitude image of from, as
// Unreal makes them: the
// direction of a texel in Unreal's world reads the image at its longitude
// and latitude, bilinear, wrapping around the longitude and clamped at the
// poles. The faces are linear floats unless the source has 8 or 16 bits.
@(private="file")
cube_long_lat :: proc(from:textures.Source,read,stored:^textures.Transfer,allocator:mem.Allocator) -> (source:textures.Source,error:unreal.Error) {
    size:=long_lat_face(from.width)
    images:=max(from.layers,1)
    if images*FACES>asset.TEXTURE_MAX_LAYERS {return {},{.Limit,0,"cube array of longitude-latitude images"}}
    source={width=size,height=size,layers=images*FACES,format=from.format,cube=true,allocator=allocator}
    allocation_error:mem.Allocator_Error
    if source.texels,allocation_error=make([]u8,textures.source_bytes(source),allocator);allocation_error!=nil {return {},{.Out_Of_Memory,0,"cube of a longitude-latitude image"}}
    w,h:=from.width,from.height
    texel :: proc(from:textures.Source,base,x,y:int,read:^textures.Transfer) -> [4]f32 {
        return textures.texel_read(from.texels,from.format,base+y*from.width+x,read)
    }
    for image in 0..<images {
        base:=image*w*h
        for face in 0..<FACES {
            for y in 0..<size {
                for x in 0..<size {
                    d:=unreal_direction(cube_direction(face,x,y,size))
                    d/=math.sqrt(d.x*d.x+d.y*d.y+d.z*d.z)
                    // LookupLongLatFloat with Unreal's swizzle of y and z undone: the pole is +Z.
                    lx:=(1+math.atan2(d.x,-d.y)/math.PI)*0.5*f32(w)
                    ly:=math.acos(clamp(d.z,-1,1))/math.PI*f32(h)
                    x0,y0:=clamp(int(lx),0,w-1),clamp(int(ly),0,h-1)
                    fx,fy:=lx-f32(x0),ly-f32(y0)
                    x1:=x0+1 if x0+1<w else 0
                    y1:=min(y0+1,h-1)
                    top:=texel(from,base,x0,y0,read)*(1-fx)+texel(from,base,x1,y0,read)*fx
                    bottom:=texel(from,base,x0,y1,read)*(1-fx)+texel(from,base,x1,y1,read)*fx
                    textures.texel_write(source.texels,source.format,((image*FACES+face)*size+y)*size+x,top*(1-fy)+bottom*fy,stored)
                }
            }
        }
    }
    return
}

// The sky Mirai draws from the first cube of faces in Mirai's order and axes
// (texture_build_input): a longitude-latitude image twice as wide as tall,
// four texels across for each of a face, with the zenith on its top row and
// the turn from -X through -Z, +X and +Z across, as sky_image in scene.slang
// reads it. Each texel is the bilinear of the face its direction lands on,
// in linear values: srgb says the texels of 8 or 16 bits have the sRGB curve.
sky_of_cube :: proc(cube:textures.Source,srgb:bool,allocator:=context.allocator) -> (sky:textures.Source,error:unreal.Error) {
    if !cube.cube || cube.width!=cube.height || cube.width<1 || cube.layers<FACES {return {},{.Unsupported_Value,0,"the faces of a cube"}}
    size:=cube.width
    sky={width=4*size,height=2*size,layers=1,format=cube.format,allocator=allocator}
    allocation_error:mem.Allocator_Error
    if sky.texels,allocation_error=make([]u8,textures.source_bytes(sky),allocator);allocation_error!=nil {return {},{.Out_Of_Memory,0,"sky of a cube"}}
    transfer:=textures.transfer_make(srgb && !textures.source_hdr(cube.format))
    texel :: proc(cube:textures.Source,face,x,y:int,transfer:^textures.Transfer) -> [4]f32 {
        return textures.texel_read(cube.texels,cube.format,(face*cube.width+y)*cube.width+x,transfer)
    }
    for row in 0..<sky.height {
        theta:=(f32(row)+0.5)/f32(sky.height)*math.PI
        for column in 0..<sky.width {
            phi:=((f32(column)+0.5)/f32(sky.width)-0.5)*2*math.PI
            face,u,v:=cube_face({math.sin(theta)*math.cos(phi),math.cos(theta),math.sin(theta)*math.sin(phi)})
            sx,sy:=(u+1)*0.5*f32(size)-0.5,(v+1)*0.5*f32(size)-0.5
            x0,y0:=clamp(int(math.floor(sx)),0,size-1),clamp(int(math.floor(sy)),0,size-1)
            x1,y1:=min(x0+1,size-1),min(y0+1,size-1)
            fx,fy:=clamp(sx-f32(x0),0,1),clamp(sy-f32(y0),0,1)
            top:=texel(cube,face,x0,y0,&transfer)*(1-fx)+texel(cube,face,x1,y0,&transfer)*fx
            bottom:=texel(cube,face,x0,y1,&transfer)*(1-fx)+texel(cube,face,x1,y1,&transfer)*fx
            textures.texel_write(sky.texels,sky.format,row*sky.width+column,top*(1-fy)+bottom*fy,&transfer)
        }
    }
    return
}
