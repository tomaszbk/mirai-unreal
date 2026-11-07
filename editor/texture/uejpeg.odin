package unreal_texture

import "core:encoding/endian"
import "core:mem"
import "project:plugins/unreal/editor/kraken"
import unreal "project:plugins/unreal/editor/package"

// UE JPEG (`.uej`): the quantized DCT coefficients of a
// baseline JPEG without its Huffman coding, cut in horizontal bands (splits)
// that Oodle compresses. A coefficient is a 16 bit value plus 0x80; a split
// keeps, per component, coefficient k of every block together, the low bytes
// of the whole split before its high bytes. Pixels match Unreal's x64 build:
// the fast integer IDCT as its SSE2 path computes it, then upsampling and
// color conversion as its SSE2 path does them, to RGBA.

UEJPEG_MAGIC :: "OOJPEG"

@(private="file") VERSION :: 4
@(private="file") MAX_SPLITS :: 16
@(private="file") MAX_SIDE :: 1<<24
@(private="file") CHUNK_HEADER :: 8 // u32 length and four tag bytes
@(private="file") IHDR_SIZE :: 16   // version, width, height as u32; bit depth, components, method, splits as u8
@(private="file") LHDR_SIZE :: 534  // blocks per component, quantization tables, APP14 transform, JFIF, component ids
@(private="file") IHDR_AT :: len(UEJPEG_MAGIC)+CHUNK_HEADER
@(private="file") LHDR_AT :: IHDR_AT+IHDR_SIZE+CHUNK_HEADER
@(private="file") SPLITS_AT :: LHDR_AT+LHDR_SIZE
@(private="file") COEFFICIENT_BIAS :: 0x80
@(private="file") METHOD_STORED :: 0 // any other method is Oodle

// Position in zigzag order of each coefficient in natural order.
@(private="file")
ZIGZAG :: [64]int{
    0,1,5,6,14,15,27,28, 2,4,7,13,16,26,29,42, 3,8,12,17,25,30,41,43, 9,11,18,24,31,40,44,53,
    10,19,23,32,39,45,52,54, 20,22,33,38,46,51,55,60, 21,34,37,47,50,56,59,61, 35,36,48,49,57,58,62,63,
}

// The AAN scale factors in 2.14 fixed point, natural order.
@(private="file")
AAN_SCALES :: [64]i64{
    16384,22725,21407,19266,16384,12873,8867,4520, 22725,31521,29692,26722,22725,17855,12299,6270,
    21407,29692,27969,25172,21407,16819,11585,5906, 19266,26722,25172,22654,19266,15137,10426,5315,
    16384,22725,21407,19266,16384,12873,8867,4520, 12873,17855,16819,15137,12873,10114,6967,3552,
    8867,12299,11585,10426,8867,6967,4799,2446, 4520,6270,5906,5315,4520,3552,2446,1247,
}
@(private="file") AAN_SHIFT :: 12

// The fast IDCT's constants in 8.8 fixed point, times 64: the SSE2 path
// multiplies them with a value shifted left by 2 and keeps the high 16 bits.
@(private="file") IDCT_1_414213562 :: 362<<6
@(private="file") IDCT_1_847759065 :: 473<<6
@(private="file") IDCT_1_082392200 :: 277<<6
@(private="file") IDCT_MINUS_1_613125930 :: -(413<<6)

// The YCbCr constants: 0.16 fixed point for the SSE2 path, and 12.20
// for the pixels of a row past its last group of 8.
@(private="file") YCC_CR_R :: 26345  // 1.402 - 1
@(private="file") YCC_CR_G :: 18734  // 1 - 0.71414
@(private="file") YCC_CB_G :: -22554 // -0.34414
@(private="file") YCC_CB_B :: -14942 // 1.772 - 2
@(private="file") YCC_GROUP :: 8
@(private="file") YCC_ROW_CR_R :: 1470096
@(private="file") YCC_ROW_CR_G :: 748832
@(private="file") YCC_ROW_CB_G :: 360864
@(private="file") YCC_ROW_CB_B :: 1858080

// Adobe APP14 transforms; without APP14 it is -1. None is RGB with three
// components and CMYK with four; any other value with four is YCbCr and alpha.
@(private="file") TRANSFORM_NONE :: 0
@(private="file") TRANSFORM_YCCK :: 2

@(private="file")
Header :: struct {
    width,height,components,splits:int,
    method:u8,
    blocks:[4][2]int,   // 8x8 blocks across and down per component
    dequant:[4][64]u16, // natural order
    transform:i8,
    jfif:bool,
    ids:[4]u8,
}

@(private="file")
Split :: struct {start,rows:[4]int,coefficients,at:int,bytes:[]u8}

// The RGBA rows from the top of a UE JPEG payload whose image measures width
// by height, as Unreal decodes it. Oodle splits need a decoder.
uejpeg_decode :: proc(bytes:[]u8,width,height:int,decoder:^kraken.Decoder,allocator:=context.allocator) -> (rgba:[]u8,error:unreal.Error) {
    h:Header
    h,error=header_read(bytes)
    if error.code!=.None {return}
    if h.width!=width || h.height!=height {return nil,{.Malformed,IHDR_AT,"UE JPEG size differs from its source size"}}

    // make_splits: each split takes the same share of every component's rows.
    shortest:=max(int)
    for c in 0..<h.components {shortest=min(shortest,h.blocks[c][1])}
    share:=(shortest+h.splits-1)/h.splits
    splits:[MAX_SPLITS]Split
    largest:=0
    at:=SPLITS_AT
    for &split,s in splits[:h.splits] {
        for c in 0..<h.components {
            rows:=h.blocks[c][1]/shortest*share
            split.start[c]=min(rows*s,h.blocks[c][1])
            split.rows[c]=min(rows*(s+1),h.blocks[c][1])-split.start[c]
            split.coefficients+=h.blocks[c][0]*split.rows[c]*64
        }
        if len(bytes)-at<CHUNK_HEADER {return nil,{.Malformed,i64(at),"UE JPEG split header"}}
        length:=int(endian.unchecked_get_u32le(bytes[at:]))
        if string(bytes[at+4:at+CHUNK_HEADER])!="SPLT" {return nil,{.Malformed,i64(at),"UE JPEG split tag"}}
        at+=CHUNK_HEADER
        if length>len(bytes)-at {return nil,{.Malformed,i64(at),"UE JPEG split size"}}
        // Unreal leaves the coefficients of an empty Oodle split unwritten.
        if (h.method==METHOD_STORED || length==0) && length!=split.coefficients*2 {return nil,{.Malformed,i64(at),"UE JPEG split size differs from its blocks"}}
        if h.method!=METHOD_STORED && length>0 && split.coefficients==0 {return nil,{.Malformed,i64(at),"UE JPEG split without blocks"}}
        split.at,split.bytes=at,bytes[at:at+length]
        at+=length
        largest=max(largest,split.coefficients*2)
    }

    // Coefficients of 16 bits, dequantized with the AAN scales the fast IDCT expects.
    zigzag,scales:=ZIGZAG,AAN_SCALES
    dequant:[4][64]i64
    for c in 0..<h.components {
        for e in 0..<64 {dequant[c][e]=i64(u16((i64(h.dequant[c][zigzag[e]])*scales[zigzag[e]]+(1<<(AAN_SHIFT-1)))>>AAN_SHIFT))}
    }
    plane_at:[5]int
    for c in 0..<h.components {plane_at[c+1]=plane_at[c]+h.blocks[c][0]*h.blocks[c][1]*64}
    allocation_error:mem.Allocator_Error
    planes:[]u8
    planes,allocation_error=make([]u8,plane_at[h.components])
    if allocation_error!=nil {return nil,{.Out_Of_Memory,0,"UE JPEG planes"}}
    defer delete(planes)
    unpacked:[]u8
    if h.method!=METHOD_STORED {
        unpacked,allocation_error=make([]u8,largest)
        if allocation_error!=nil {return nil,{.Out_Of_Memory,0,"UE JPEG coefficients"}}
    }
    defer delete(unpacked)
    for split in splits[:h.splits] {
        coefficients:=split.bytes
        if h.method!=METHOD_STORED && len(split.bytes)>0 {
            if decoder==nil {return nil,{.Compressed,0,"Oodle UE JPEG splits need a kraken.Decoder"}}
            coefficients=unpacked[:split.coefficients*2]
            switch kraken.decode(decoder,split.bytes,coefficients) {
            case .None:
            case .Unsupported:return nil,{.Unsupported_Value,i64(split.at),"UE JPEG split uses an Oodle compressor other than Kraken"}
            case .Truncated,.Malformed:return nil,{.Malformed,i64(split.at),"Oodle UE JPEG split"}
            }
        }
        low,high:=coefficients[:split.coefficients],coefficients[split.coefficients:]
        first:=0
        for c in 0..<h.components {
            across:=h.blocks[c][0]
            blocks:=across*split.rows[c]
            stride:=across*8
            for y in 0..<split.rows[c] {
                for x in 0..<across {
                    block:[64]i16
                    for e in 0..<64 {
                        d:=first+e*blocks+y*across+x
                        value:=i64(transmute(i16)(u16(low[d])|u16(high[d])<<8))
                        block[zigzag[e]]=i16((value-COEFFICIENT_BIAS)*dequant[c][e])
                    }
                    idct_block(&block,planes[plane_at[c]:],((split.start[c]+y)*8)*stride+x*8,stride)
                }
            }
            first+=blocks*64
        }
    }

    // Upsampling row by row, then RGBA.
    across_max,down_max:=1,1
    for c in 0..<h.components {across_max,down_max=max(across_max,h.blocks[c][0]),max(down_max,h.blocks[c][1])}
    Resample :: struct {hs,vs,ystep,ypos,lores,line0,line1,stride,rows:int}
    resample:[4]Resample
    lines:[]u8
    lines,allocation_error=make([]u8,h.components*(width+3))
    if allocation_error!=nil {return nil,{.Out_Of_Memory,0,"UE JPEG lines"}}
    defer delete(lines)
    for c in 0..<h.components {
        hs,vs:=across_max/h.blocks[c][0],down_max/h.blocks[c][1]
        resample[c]={hs=hs,vs=vs,ystep=vs>>1,lores=(width+hs-1)/hs,stride=h.blocks[c][0]*8,rows=h.blocks[c][1]*8}
    }
    rgba,allocation_error=make([]u8,width*height*4,allocator)
    if allocation_error!=nil {return nil,{.Out_Of_Memory,0,"UE JPEG pixels"}}
    ids:=h.ids
    is_rgb:=h.components==3 && ((ids[0]=='R' && ids[1]=='G' && ids[2]=='B') || (h.transform==TRANSFORM_NONE && !h.jfif))
    row:[4][]u8
    for j in 0..<height {
        for c in 0..<h.components {
            r:=&resample[c]
            plane:=planes[plane_at[c]:plane_at[c+1]]
            bottom:=r.ystep>=r.vs>>1
            near,far:=r.line0,r.line1
            if bottom {near,far=r.line1,r.line0}
            row[c]=row_resample(lines[c*(width+3):][:width+3],plane[near*r.stride:],plane[far*r.stride:],r.lores,r.hs,r.vs,bottom)
            r.ystep+=1
            if r.ystep>=r.vs {
                r.ystep=0
                r.line0=r.line1
                r.ypos+=1
                if r.ypos<(height+r.vs-1)/r.vs && r.ypos<r.rows {r.line1+=1}
            }
        }
        out:=rgba[j*width*4:][:width*4]
        switch h.components {
        case 1:
            for i in 0..<width {out[i*4],out[i*4+1],out[i*4+2],out[i*4+3]=row[0][i],row[0][i],row[0][i],255}
        case 3:
            if is_rgb {
                for i in 0..<width {out[i*4],out[i*4+1],out[i*4+2],out[i*4+3]=row[0][i],row[1][i],row[2][i],255}
            } else {
                ycbcr_to_rgba(out,row[0],row[1],row[2],width)
            }
        case 4:
            switch h.transform {
            case TRANSFORM_NONE:
                for i in 0..<width {
                    k:=row[3][i]
                    out[i*4],out[i*4+1],out[i*4+2],out[i*4+3]=blinn(row[0][i],k),blinn(row[1][i],k),blinn(row[2][i],k),255
                }
            case TRANSFORM_YCCK:
                ycbcr_to_rgba(out,row[0],row[1],row[2],width)
                for i in 0..<width {
                    k:=row[3][i]
                    out[i*4],out[i*4+1],out[i*4+2]=blinn(255-out[i*4],k),blinn(255-out[i*4+1],k),blinn(255-out[i*4+2],k)
                }
            case:
                ycbcr_to_rgba(out,row[0],row[1],row[2],width)
                for i in 0..<width {out[i*4+3]=row[3][i]}
            }
        }
    }
    return
}

// The IHDR and LHDR chunks, with the checks that keep the decoder from
// reading outside its planes.
@(private="file")
header_read :: proc(bytes:[]u8) -> (h:Header,error:unreal.Error) {
    if len(bytes)<SPLITS_AT || string(bytes[:len(UEJPEG_MAGIC)])!=UEJPEG_MAGIC {return {},{.Malformed,0,"UE JPEG header"}}
    if string(bytes[IHDR_AT-4:IHDR_AT])!="IHDR" {return {},{.Malformed,IHDR_AT-4,"UE JPEG IHDR tag"}}
    if string(bytes[LHDR_AT-4:LHDR_AT])!="LHDR" {return {},{.Malformed,LHDR_AT-4,"UE JPEG LHDR tag"}}
    ihdr:=bytes[IHDR_AT:]
    if endian.unchecked_get_u32le(ihdr)!=VERSION {return {},{.Unsupported_Value,IHDR_AT,"UE JPEG version"}}
    h.width=int(endian.unchecked_get_u32le(ihdr[4:]))
    h.height=int(endian.unchecked_get_u32le(ihdr[8:]))
    if h.width==0 || h.height==0 || h.width>MAX_SIDE || h.height>MAX_SIDE {return {},{.Malformed,IHDR_AT+4,"UE JPEG size"}}
    if ihdr[12]!=8 {return {},{.Malformed,IHDR_AT+12,"UE JPEG bit depth"}}
    h.components=int(ihdr[13])
    if h.components!=1 && h.components!=3 && h.components!=4 {return {},{.Malformed,IHDR_AT+13,"UE JPEG component count"}}
    if h.width*h.height*h.components>int(max(i32)) {return {},{.Limit,IHDR_AT+4,"UE JPEG size"}}
    h.method=ihdr[14]
    h.splits=int(ihdr[15])
    if h.splits<1 || h.splits>MAX_SPLITS {return {},{.Malformed,IHDR_AT+15,"UE JPEG split count"}}
    lhdr:=bytes[LHDR_AT:]
    for c in 0..<4 {
        for d in 0..<2 {h.blocks[c][d]=int(endian.unchecked_get_u16le(lhdr[(c*2+d)*2:]))}
        for e in 0..<64 {h.dequant[c][e]=endian.unchecked_get_u16le(lhdr[16+(c*64+e)*2:])}
    }
    h.transform=transmute(i8)lhdr[528]
    h.jfif=lhdr[529]!=0
    for c in 0..<4 {h.ids[c]=lhdr[530+c]}
    if h.transform<-1 || h.transform>TRANSFORM_YCCK {return {},{.Malformed,LHDR_AT+528,"UE JPEG color transform"}}
    across_max,down_max:=1,1
    for c in 0..<4 {
        if c>=h.components {
            if h.blocks[c]!={0,0} {return {},{.Malformed,LHDR_AT,"UE JPEG blocks of a missing component"}}
            continue
        }
        if h.blocks[c][0]==0 || h.blocks[c][1]==0 {return {},{.Malformed,LHDR_AT,"UE JPEG component without blocks"}}
        across_max,down_max=max(across_max,h.blocks[c][0]),max(down_max,h.blocks[c][1])
    }
    for c in 0..<h.components {
        across,down:=h.blocks[c][0],h.blocks[c][1]
        hs,vs:=across_max/across,down_max/down
        if across_max%across!=0 || down_max%down!=0 {return {},{.Malformed,LHDR_AT,"UE JPEG component blocks"}}
        if (hs!=1 && hs!=2) || (vs!=1 && vs!=2) {return {},{.Unsupported_Value,LHDR_AT,"UE JPEG chroma subsampling other than 1 or 2"}}
        if across*8>(h.width+7)/8*8+8 || across*8<h.width/8*8/hs {return {},{.Malformed,LHDR_AT,"UE JPEG blocks across"}}
        // Unreal reads past the plane for these; no encoder writes them.
        if across*8<(h.width+hs-1)/hs || down*8>(h.height+7)/8*8+8 {return {},{.Malformed,LHDR_AT,"UE JPEG blocks outside the image"}}
    }
    return
}

@(private="file")
mulhi :: #force_inline proc "contextless" (a,b:i16) -> i16 {return i16((i32(a)*i32(b))>>16)}

// One 1D pass of the fast IDCT with 16 bit wrapping arithmetic.
@(private="file")
idct_1d :: #force_inline proc "contextless" (s:[8]i16) -> (o:[8]i16) {
    tmp10:=s[0]+s[4]
    tmp11:=s[0]-s[4]
    tmp13:=s[2]+s[6]
    tmp12:=mulhi((s[2]-s[6])<<2,IDCT_1_414213562)-tmp13
    tmp0:=tmp10+tmp13
    tmp3:=tmp10-tmp13
    tmp1:=tmp11+tmp12
    tmp2:=tmp11-tmp12
    z13:=s[5]+s[3]
    z10:=s[5]-s[3]
    z11:=s[1]+s[7]
    z12:=s[1]-s[7]
    tmp7:=z11+z13
    tmp11=mulhi((z11-z13)<<2,IDCT_1_414213562)
    z5:=mulhi((z10+z12)<<2,IDCT_1_847759065)
    tmp10=mulhi(z12<<2,IDCT_1_082392200)-z5
    tmp12=mulhi(z10<<2,IDCT_MINUS_1_613125930)-z10+z5
    tmp6:=tmp12-tmp7
    tmp5:=tmp11-tmp6
    tmp4:=tmp10+tmp5
    return {tmp0+tmp7,tmp1+tmp6,tmp2+tmp5,tmp3-tmp4,tmp3+tmp4,tmp2-tmp5,tmp1-tmp6,tmp0-tmp7}
}

// Columns, then rows; an 8x8 block of samples into out at stride.
@(private="file")
idct_block :: proc "contextless" (block:^[64]i16,out:[]u8,at,stride:int) {
    work:[8][8]i16
    for column in 0..<8 {
        s:[8]i16
        for r in 0..<8 {s[r]=block[r*8+column]}
        o:=idct_1d(s)
        for r in 0..<8 {work[r][column]=o[r]}
    }
    for r in 0..<8 {
        o:=idct_1d(work[r])
        line:=out[at+r*stride:][:8]
        for m in 0..<8 {line[m]=u8(clamp((o[m]>>5)+128,0,255))}
    }
}

// One output row of a component from its near and far rows.
@(private="file")
row_resample :: proc(out,near,far:[]u8,w,hs,vs:int,bottom:bool) -> []u8 {
    switch {
    case hs==1 && vs==1:
        return near[:w]
    case hs==1:
        bias:=1 if bottom else 2
        for i in 0..<w {out[i]=u8((3*int(near[i])+int(far[i])+bias)>>2)}
    case vs==1:
        if w==1 {out[0],out[1]=near[0],near[0];return out}
        out[0]=near[0]
        out[1]=u8((int(near[0])*3+int(near[1])+2)>>2)
        i:=1
        for ;i<w-1;i+=1 {
            n:=3*int(near[i])
            out[i*2]=u8((n+int(near[i-1])+1)>>2)
            out[i*2+1]=u8((n+int(near[i+1])+2)>>2)
        }
        out[i*2]=u8((int(near[w-1])*3+int(near[w-2])+1)>>2)
        out[i*2+1]=near[w-1]
    case:
        if w==1 {v:=u8((3*int(near[0])+int(far[0])+2)>>2);out[0],out[1]=v,v;return out}
        t1:=3*int(near[0])+int(far[0])
        out[0]=u8((t1+2)>>2)
        for i in 1..<w {
            t0:=t1
            t1=3*int(near[i])+int(far[i])
            out[i*2-1]=u8((3*t0+t1+7)>>4)
            out[i*2]=u8((3*t1+t0+8)>>4)
        }
        out[w*2-1]=u8((t1+1)>>2)
    }
    return out
}

@(private="file")
saturate :: #force_inline proc "contextless" (v:i16) -> u8 {return u8(clamp(v,0,255))}

@(private="file")
ycbcr_to_rgba :: proc(out,y,cb,cr:[]u8,count:int) {
    groups:=count/YCC_GROUP*YCC_GROUP
    for i in 0..<groups {
        yw:=transmute(i16)((u16(y[i])<<8|0x80)>>4)
        cbw:=i16(transmute(i8)(cb[i]~0x80))<<4
        crw:=i16(transmute(i8)(cr[i]~0x80))<<4
        r:=(mulhi(YCC_CR_R,crw)+yw+crw)>>4
        gw:=i16(clamp((i32(cbw)*YCC_CB_G+i32(crw)*YCC_CR_G)>>16,i32(min(i16)),i32(max(i16))))
        g:=(gw-crw+yw)>>4
        b:=(yw+mulhi(cbw,YCC_CB_B)+cbw+cbw)>>4
        out[i*4],out[i*4+1],out[i*4+2],out[i*4+3]=saturate(r),saturate(g),saturate(b),255
    }
    for i in groups..<count {
        y_fixed:=i32(y[i])<<20+1<<19
        cr_v,cb_v:=i32(cr[i])-128,i32(cb[i])-128
        r:=(y_fixed+cr_v*YCC_ROW_CR_R)>>20
        g:=(y_fixed-cr_v*YCC_ROW_CR_G-cb_v*YCC_ROW_CB_G)>>20
        b:=(y_fixed+cb_v*YCC_ROW_CB_B)>>20
        out[i*4],out[i*4+1],out[i*4+2],out[i*4+3]=u8(clamp(r,0,255)),u8(clamp(g,0,255)),u8(clamp(b,0,255)),255
    }
}

// x*y/255 rounded: how CMYK is multiplied by K.
@(private="file")
blinn :: #force_inline proc "contextless" (x,y:u8) -> u8 {
    t:=u32(x)*u32(y)+128
    return u8((t+(t>>8))>>8)
}
