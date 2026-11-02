package unreal_vfx_editor

import "core:fmt"
import "core:strconv"
import "core:strings"

// The HLSL Niagara's translator generates, read as text: its preprocessor
// conditions evaluated for one stage, its top-level declarations and the
// fields of its structs. It is not a general HLSL parser: it reads the shape
// the translator writes.

Hlsl_Kind :: enum u8 {Other,Struct,Cbuffer,Function,Prototype,Variable}

// A top-level declaration: a struct, a cbuffer, a function with its body or
// its prototype, a global variable, or a line of the preprocessor.
Hlsl_Item :: struct {
    kind:Hlsl_Kind,
    name:string,
    text:string,   // the whole declaration
    result:string, // of a function: what it returns
    params:string, // of a function: between its parentheses
    body:string,   // of a function, struct or cbuffer: between its braces
}

Hlsl_Field :: struct {type,name:string}

// The lines of text whose conditions hold with the values of defines; a name
// without one is 0. Lines of the preprocessor other than conditions stay.
hlsl_preprocess :: proc(text:string,defines:map[string]i64,allocator:=context.temp_allocator) -> string {
    Level :: struct {active,taken,parent:bool}
    stack:=make([dynamic]Level,context.temp_allocator)
    out:=strings.builder_make(allocator)
    active:=true
    rest:=text
    for line in strings.split_lines_iterator(&rest) {
        trimmed:=strings.trim_left_space(line)
        if !strings.has_prefix(trimmed,"#") {
            if active {strings.write_string(&out,line);strings.write_byte(&out,'\n')}
            continue
        }
        directive:=strings.trim_left_space(trimmed[1:])
        word_end:=0
        for word_end<len(directive) && (is_ident(directive[word_end])) {word_end+=1}
        word,argument:=directive[:word_end],strings.trim_space(hlsl_strip_comment(directive[word_end:]))
        switch word {
        case "if","ifdef","ifndef":
            holds:bool
            switch word {
            case "if": holds=hlsl_expression(argument,defines)!=0
            case "ifdef": _,holds=defines[argument]
            case "ifndef": _,defined:=defines[argument];holds=!defined
            }
            append(&stack,Level{active=active && holds,taken=holds,parent=active})
            active=active && holds
        case "elif":
            if len(stack)==0 {continue}
            top:=&stack[len(stack)-1]
            holds:=!top.taken && hlsl_expression(argument,defines)!=0
            top.active=top.parent && holds
            top.taken||=holds
            active=top.active
        case "else":
            if len(stack)==0 {continue}
            top:=&stack[len(stack)-1]
            top.active=top.parent && !top.taken
            top.taken=true
            active=top.active
        case "endif":
            if len(stack)==0 {continue}
            active=stack[len(stack)-1].parent
            pop(&stack)
        case:
            if active {strings.write_string(&out,line);strings.write_byte(&out,'\n')}
        }
    }
    return strings.to_string(out)
}

@(private)
hlsl_strip_comment :: proc(text:string) -> string {
    if at:=strings.index(text,"//");at>=0 {return text[:at]}
    return text
}

@(private)
is_ident :: proc(c:u8) -> bool {return c=='_' || (c>='a' && c<='z') || (c>='A' && c<='Z') || (c>='0' && c<='9')}

// The value of a condition of the preprocessor: integers, names, defined(),
// !, unary -, * / %, + -, comparisons, == !=, && and ||.
hlsl_expression :: proc(text:string,defines:map[string]i64) -> i64 {
    Parser :: struct {text:string,at:int,defines:map[string]i64}
    skip :: proc(p:^Parser) {for p.at<len(p.text) && (p.text[p.at]==' ' || p.text[p.at]=='\t') {p.at+=1}}
    take :: proc(p:^Parser,token:string) -> bool {
        skip(p)
        if strings.has_prefix(p.text[p.at:],token) {p.at+=len(token);return true}
        return false
    }
    primary :: proc(p:^Parser) -> i64 {
        skip(p)
        if take(p,"(") {
            v:=or_(p)
            take(p,")")
            return v
        }
        start:=p.at
        for p.at<len(p.text) && is_ident(p.text[p.at]) {p.at+=1}
        word:=p.text[start:p.at]
        if word=="" {p.at=len(p.text);return 0}
        if word=="defined" {
            open:=take(p,"(")
            skip(p)
            name_start:=p.at
            for p.at<len(p.text) && is_ident(p.text[p.at]) {p.at+=1}
            _,found:=p.defines[p.text[name_start:p.at]]
            if open {take(p,")")}
            return found?1:0
        }
        if word[0]>='0' && word[0]<='9' {
            trimmed:=strings.trim_right(word,"uUlL")
            if v,ok:=strconv.parse_i64(trimmed);ok {return v}
            return 0
        }
        return p.defines[word]
    }
    unary :: proc(p:^Parser) -> i64 {
        if take(p,"!") {return unary(p)==0?1:0}
        if take(p,"-") {return -unary(p)}
        return primary(p)
    }
    mul :: proc(p:^Parser) -> i64 {
        v:=unary(p)
        for {
            switch {
            case take(p,"*"): v*=unary(p)
            case take(p,"/"): d:=unary(p);v=d!=0?v/d:0
            case take(p,"%"): d:=unary(p);v=d!=0?v%d:0
            case: return v
            }
        }
    }
    add :: proc(p:^Parser) -> i64 {
        v:=mul(p)
        for {
            switch {
            case take(p,"+"): v+=mul(p)
            case !strings.has_prefix(p.text[min(p.at+1,len(p.text)):],"-") && take(p,"-"): v-=mul(p)
            case: return v
            }
        }
    }
    relation :: proc(p:^Parser) -> i64 {
        v:=add(p)
        for {
            switch {
            case take(p,"<="): v=v<=add(p)?1:0
            case take(p,">="): v=v>=add(p)?1:0
            case take(p,"<"): v=v<add(p)?1:0
            case take(p,">"): v=v>add(p)?1:0
            case: return v
            }
        }
    }
    equality :: proc(p:^Parser) -> i64 {
        v:=relation(p)
        for {
            switch {
            case take(p,"=="): v=v==relation(p)?1:0
            case take(p,"!="): v=v!=relation(p)?1:0
            case: return v
            }
        }
    }
    and_ :: proc(p:^Parser) -> i64 {
        v:=equality(p)
        for take(p,"&&") {
            w:=equality(p)
            v=(v!=0 && w!=0)?1:0
        }
        return v
    }
    or_ :: proc(p:^Parser) -> i64 {
        v:=and_(p)
        for take(p,"||") {
            w:=and_(p)
            v=(v!=0 || w!=0)?1:0
        }
        return v
    }
    p:=Parser{text=text,defines=defines}
    return or_(&p)
}

// The top-level declarations of a preprocessed text, in order.
hlsl_items :: proc(text:string,allocator:=context.temp_allocator) -> []Hlsl_Item {
    items:=make([dynamic]Hlsl_Item,allocator)
    at:=0
    for at<len(text) {
        // Spaces and comments between declarations.
        c:=text[at]
        if c==' ' || c=='\t' || c=='\r' || c=='\n' {at+=1;continue}
        if strings.has_prefix(text[at:],"//") {
            for at<len(text) && text[at]!='\n' {at+=1}
            continue
        }
        if strings.has_prefix(text[at:],"/*") {
            end:=strings.index(text[at+2:],"*/")
            at=end<0?len(text):at+2+end+2
            continue
        }
        start:=at
        if c=='#' {
            for at<len(text) && text[at]!='\n' {at+=1}
            append(&items,Hlsl_Item{kind=.Other,text=text[start:at]})
            continue
        }
        parens,braces,brackets:=0,0,0
        body_start,body_end:=-1,-1
        params_start,params_end:=-1,-1
        scan: for at<len(text) {
            switch {
            case strings.has_prefix(text[at:],"//"):
                for at<len(text) && text[at]!='\n' {at+=1}
                continue scan
            case strings.has_prefix(text[at:],"/*"):
                end:=strings.index(text[at+2:],"*/")
                at=end<0?len(text):at+2+end+2
                continue scan
            }
            switch text[at] {
            // An attribute before a function ([numthreads(...)]) is not its parameters.
            case '[': brackets+=1
            case ']': brackets-=1
            case '(':
                if parens==0 && braces==0 && brackets==0 && params_start<0 && body_start<0 {params_start=at+1}
                parens+=1
            case ')':
                parens-=1
                if parens==0 && braces==0 && brackets==0 && params_end<0 && params_start>=0 && body_start<0 {params_end=at}
            case '{':
                if braces==0 && parens==0 {body_start=at+1}
                braces+=1
            case '}':
                braces-=1
                if braces==0 && parens==0 {
                    body_end=at
                    at+=1
                    // A struct ends with ;
                    look:=at
                    for look<len(text) && (text[look]==' ' || text[look]=='\t' || text[look]=='\r' || text[look]=='\n') {look+=1}
                    if look<len(text) && text[look]==';' {at=look+1}
                    break scan
                }
            case ';':
                if braces==0 && parens==0 {
                    at+=1
                    break scan
                }
            }
            at+=1
        }
        item:=Hlsl_Item{text=text[start:at]}
        head:=text[start:body_start>=0?body_start-1:at]
        words:=hlsl_words(head)
        switch {
        case len(words)>=2 && words[0]=="struct":
            item.kind,item.name=.Struct,words[1]
        case len(words)>=2 && words[0]=="cbuffer":
            item.kind,item.name=.Cbuffer,words[1]
        case params_start>=0 && params_end>=params_start:
            before:=strings.trim_space(text[start:params_start-1])
            name_start:=len(before)
            for name_start>0 && is_ident(before[name_start-1]) {name_start-=1}
            item.name=before[name_start:]
            item.result=strings.trim_space(before[:name_start])
            item.params=text[params_start:params_end]
            item.kind=body_start>=0?.Function:.Prototype
        case:
            item.kind=.Variable
            if len(words)>=2 {item.name=words[len(words)-1]}
            // static float X = 1.0; names X.
            if eq:=strings.index_byte(head,'=');eq>=0 {
                before:=hlsl_words(head[:eq])
                if len(before)>0 {item.name=before[len(before)-1]}
            }
        }
        if body_start>=0 && body_end>=body_start {item.body=text[body_start:body_end]}
        append(&items,item)
    }
    return items[:]
}

// The words the declarations roots reach use: a declaration is reached when
// a reached text uses its name, from the roots on. A word only counts as a
// name, wherever it is: what is reached is never less than what the code
// calls. The declarations whose names are not among them are dead code.
hlsl_reached :: proc(items:[]Hlsl_Item,roots:[]string,allocator:=context.temp_allocator) -> map[string]struct{} {
    // The items of each name, chained: first[name], then next[i].
    first:=make(map[string]int,len(items),context.temp_allocator)
    next:=make([]int,len(items),context.temp_allocator)
    for item,i in items {
        next[i]=-1
        if item.name=="" || item.kind==.Other || item.kind==.Cbuffer {continue}
        if at,found:=first[item.name];found {next[i]=at}
        first[item.name]=i
    }
    used:=make(map[string]struct{},allocator)
    pending:=make([dynamic]string,context.temp_allocator)
    reach :: proc(used:^map[string]struct{},pending:^[dynamic]string,word:string) {
        if word in used {return}
        used[word]={}
        append(pending,word)
    }
    for root in roots {reach(&used,&pending,root)}
    for len(pending)>0 {
        name:=pop(&pending)
        for i:=first[name] or_else -1;i>=0;i=next[i] {
            text:=items[i].text
            at:=0
            for at<len(text) {
                if !is_ident(text[at]) {at+=1;continue}
                start:=at
                for at<len(text) && is_ident(text[at]) {at+=1}
                if text[start]<'0' || text[start]>'9' {reach(&used,&pending,text[start:at])}
            }
        }
    }
    return used
}

// The words of a declaration: names, without punctuation.
@(private)
hlsl_words :: proc(text:string) -> []string {
    words:=make([dynamic]string,context.temp_allocator)
    at:=0
    for at<len(text) {
        if !is_ident(text[at]) {at+=1;continue}
        start:=at
        for at<len(text) && is_ident(text[at]) {at+=1}
        append(&words,text[start:at])
    }
    return words[:]
}

// The fields of the body of a struct or cbuffer: `type name;` each.
hlsl_fields :: proc(body:string) -> []Hlsl_Field {
    fields:=make([dynamic]Hlsl_Field,context.temp_allocator)
    rest:=body
    for {
        semicolon:=strings.index_byte(rest,';')
        if semicolon<0 {break}
        declaration:=strings.trim_space(hlsl_strip_comment_lines(rest[:semicolon]))
        rest=rest[semicolon+1:]
        words:=hlsl_words(declaration)
        if len(words)<2 {continue}
        name:=words[len(words)-1]
        // An array keeps its size in the name: `int4 X[2]` has the words int4, X, 2.
        if strings.contains(declaration,"[") {
            name=words[1]
            append(&fields,Hlsl_Field{type=strings.trim_space(declaration[:strings.index(declaration,name)]),name=strings.concatenate({name,declaration[strings.index_byte(declaration,'['):]},context.temp_allocator)})
            continue
        }
        append(&fields,Hlsl_Field{type=strings.trim_space(declaration[:len(declaration)-len(name)]),name=name})
    }
    return fields[:]
}

@(private)
hlsl_strip_comment_lines :: proc(text:string) -> string {
    out:=strings.builder_make(context.temp_allocator)
    rest:=text
    for line in strings.split_lines_iterator(&rest) {
        trimmed:=strings.trim_space(line)
        if strings.has_prefix(trimmed,"//") || strings.has_prefix(trimmed,"#") {continue}
        strings.write_string(&out,hlsl_strip_comment(line))
        strings.write_byte(&out,'\n')
    }
    return strings.to_string(out)
}

// The parameters of a function: their types and names, in order.
hlsl_params :: proc(params:string) -> []Hlsl_Field {
    out:=make([dynamic]Hlsl_Field,context.temp_allocator)
    for part in strings.split(params,",",context.temp_allocator) {
        words:=hlsl_words(part)
        if len(words)<2 {continue}
        name:=words[len(words)-1]
        type:=strings.trim_space(part[:strings.last_index(part,name)])
        append(&out,Hlsl_Field{type=type,name=name})
    }
    return out[:]
}

// A name of Niagara as its translator writes it in HLSL: each part
// between dots trimmed, joined by '_'; letters, digits and '_' stay,
// whitespace goes, any other character is ASC and its code; a part that
// starts with a digit starts with INTEGER_, and "__" is ASC95ASC95.
@(private)
niagara_symbol :: proc(name:string) -> string {
    out:=strings.builder_make(context.temp_allocator)
    rest:=name
    first:=true
    for part in strings.split_iterator(&rest,".") {
        trimmed:=strings.trim_space(part)
        if trimmed=="" {continue}
        if !first {strings.write_byte(&out,'_')}
        first=false
        if trimmed[0]>='0' && trimmed[0]<='9' {strings.write_string(&out,"INTEGER_")}
        for r in trimmed {
            switch {
            case r<128 && is_ident(u8(r)): strings.write_rune(&out,r)
            case strings.is_space(r): // whitespace goes
            case: fmt.sbprintf(&out,"ASC%d",int(r))
            }
        }
    }
    symbol,_:=strings.replace_all(strings.to_string(out),"__","ASC95ASC95",context.temp_allocator)
    return symbol
}
