package unreal_scene

import "core:fmt"
import "core:math"
import "core:strings"
import "mirai:asset"
import "project:plugins/unreal/editor/level"
import "mirai:engine/gui"
import "mirai:host"
import "mirai:std/base"
import "mirai:ui"

// A TextRenderComponent: its text on a .ui of its own, which a World_Widget
// shows fixed at the entity of the component, facing where the component
// faces (Unreal's +X, Mirai's +Z), a line WorldSize tall, in its color and
// aligned to the component as Unreal aligns it. "<br>" breaks a line, as in
// Unreal. Texts alike share their .ui.
@(private)
text_add :: proc(c:^Context,a,k:int) -> bool {
    d:=c.d
    ref:=d.components[k].ref
    text,_:=level.string_of(d,ref,"Text")
    if strings.trim_space(text)=="" {return false}
    text,_=strings.replace_all(text,"<br>","\n",context.temp_allocator)
    world_size,_:=level.real_of(d,ref,"WorldSize",26)
    y_scale,_:=level.real_of(d,ref,"YScale",1)
    color,_:=color_of(d,ref,"TextRenderColor",{1,1,1})
    horizontal,_:=level.enum_of(d,ref,"HorizontalAlignment","EHTA_Left")
    vertical,_:=level.enum_of(d,ref,"VerticalAlignment","EVRTA_TextBottom")

    // Layout units of a centimetre: a line is WorldSize units tall.
    size:=f32(world_size*y_scale)
    lines,longest:=0,0
    rest:=text
    for line in strings.split_lines_iterator(&rest) {lines+=1;longest=max(longest,len(line))}
    width:=max(f32(longest),1)*size*TEXT_ADVANCE
    height:=f32(max(lines,1))*size*ui.TEXT_LINE

    pivot:ui.Anchor
    align_x:ui.Align
    switch horizontal {
    case "EHTA_Center":align_x=.Center
    case "EHTA_Right":align_x=.End
    case:align_x=.Start
    }
    row:=0
    switch vertical {
    case "EVRTA_TextTop","EVRTA_QuadTop":row=0
    case "EVRTA_TextCenter":row=1
    case:row=2
    }
    pivots:=[3][3]ui.Anchor{{.Top_Left,.Top_Center,.Top_Right},{.Center_Left,.Center,.Center_Right},{.Bottom_Left,.Bottom_Center,.Bottom_Right}}
    pivot=pivots[row][int(align_x)]

    shown:ui.Color={srgb_byte(color.r),srgb_byte(color.g),srgb_byte(color.b),255}
    hash:=base.name_hash(text)
    hash=base.hash_combine(hash,u64(transmute(u32)size))
    hash=base.hash_combine(hash,u64(transmute(u32)shown))
    hash=base.hash_combine(hash,u64(align_x))
    id,made:=text_ui(c,text,size,width,height,shown,align_x,hash)
    if !made {return false}
    e:=component_entity(c,a,k) or_return
    widget:=gui.WORLD_WIDGET_DEFAULT
    widget.asset=id
    widget.size={width,height}
    widget.sizing=.Meters
    widget.scale=0.01
    widget.facing=.Fixed
    widget.pivot=pivot
    widget.passive=true
    return component_set(c,e,"World_Widget",&widget)
}

// The advance of a character in sizes, wide enough for the text of a line.
@(private) TEXT_ADVANCE :: f32(0.6)

// The .ui that shows a text: one per text, size, color and alignment.
@(private)
text_ui :: proc(c:^Context,text:string,size,width,height:f32,color:ui.Color,align_x:ui.Align,hash:u64) -> (id:base.Asset_Id,ok:bool) {
    if found,seen:=c.texts[hash];seen {return found,found!={}}
    defer c.texts[hash]=id
    name:=fmt.tprintf("Text_%08x",u32(hash))
    path:string
    info:asset.Import_Info
    id,path,info=asset_place(c,asset.KIND_UI,name,len(c.texts),".ui")
    texts:=make([dynamic]u8,context.temp_allocator)
    data:=ui.Tree_Data{text=texts[:],
        styles={{},{text={size=size,color=color,align_x=align_x}}},
        nodes={ui.tree_node_record(&texts,-1,{kind=.Text,name="text",style=1,text=text,layout={width=ui.fixed(width),height=ui.fixed(height)}})},
    }
    data.text=texts[:]
    doc:asset.Document
    if error:=host.ui_tree_document(&doc,c.types,id,data,{},context.temp_allocator);error!=.None {
        warn(c,"the text %q could not be written (%v)",text,error)
        id={}
        return
    }
    defer asset.document_destroy(&doc)
    if asset.import_put(&doc,c.types,&info)!=.None {return {},fail_write(c,"the text %s",name)}
    bytes,error:=asset.document_bytes(&doc,context.temp_allocator)
    if error!=.None {return {},fail_write(c,"the text %s",name)}
    if !asset_write(c,id,asset.KIND_UI,name,path,bytes,fmt.tprintf("%d characters",len(text))) {id={};return}
    return id,true
}

// A linear channel as the sRGB byte the interface takes.
@(private)
srgb_byte :: proc(linear:f32) -> u8 {
    v:=clamp(linear,0,1)
    s:=v<=0.0031308?12.92*v:1.055*math.pow(v,1/2.4)-0.055
    return u8(clamp(s*255+0.5,0,255))
}
