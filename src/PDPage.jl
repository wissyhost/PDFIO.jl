export PDPage,
       pdPageGetContents,
       pdPageIsEmpty,
       pdPageGetCosObject,
       pdPageGetContentObjects,
       pdPageExtractText

import ..Cos: CosXString

abstract type PDPage end

"""
```
    pdPageGetCosObject(page::PDPage) -> CosObject
```
PDF document format is developed in two layers. A logical PDF document information is
represented over a physical file structure called COS. This method provides the internal
COS object associated with the page object.
"""
pdPageGetCosObject(page::PDPage) = page.cospage

"""
```
    pdPageGetContents(page::PDPage) -> CosObject
```
Page rendering objects are normally stored in a `CosStream` object in a PDF file. This
method provides access to the stream object.

Please refer to the PDF specification for further details.
"""
function pdPageGetContents(page::PDPage)
    if (page.contents === CosNull)
        ref = get_page_content_ref(page)
        page.contents = get_page_contents(page, ref)
    end
    return page.contents
end

"""
```
    pdPageIsEmpty(page::PDPage) -> Bool
```
Returns `true` when the page has no associated content object.
"""
function pdPageIsEmpty(page::PDPage)
    return page.contents === CosNull && get_page_content_ref(page) === CosNull
end

"""
```
    pdPageGetContentObjects(page::PDPage) -> CosObject
```
Page rendering objects are normally stored in a `CosStream` object in a PDF file. This
method provides access to the stream object.
"""
function pdPageGetContentObjects(page::PDPage)
    if (isnull(page.content_objects))
        load_page_objects(page)
    end
    return get(page.content_objects)
end

function pdPageEvalContent(page::PDPage)
    state = init_graphics_state()
    state[end][:page] = page
    evalContent!(pdPageGetContentObjects(page), state)
    return state
end

"""
```
    pdPageExtractText(io::IO, page::PDPage) -> IO
```
Extracts the text from the `page`. This extraction works best for tagged PDF files.
For PDFs not tagged, some line and word breaks will not be extracted properly.
"""
function pdPageExtractText(io::IO, page::PDPage)
    state = pdPageEvalContent(page)
    show_text_layout!(io, state)
    return io
end

mutable struct PDPageImpl <: PDPage
  doc::PDDocImpl
  cospage::CosObject
  contents::CosObject
  content_objects::Nullable{PDPageObjectGroup}
  fums::Dict{CosName, FontUnicodeMapping}
  PDPageImpl(doc,cospage,contents)=
    new(doc, cospage, contents, Nullable{PDPageObjectGroup}(), Dict())
end

PDPageImpl(doc::PDDocImpl, cospage::CosObject) = PDPageImpl(doc, cospage,CosNull)

#=This function is added as non-exported type. PDPage may need other attributes
which will make the constructor complex. This is the default with all default
values.
=#
create_pdpage(doc::PDDocImpl, cospage::CosObject) = PDPageImpl(doc, cospage)
create_pdpage(doc::PDDocImpl, cospage::CosNullType) =
    throw(ErorException(E_INVALID_OBJECT))
#=
This will return a CosArray of ref or ref to a stream. This needs to be
converted to an actual stream object
=#
get_page_content_ref(page::PDPageImpl) = get(page.cospage, cn"Contents")

function get_page_contents(page::PDPageImpl, contents::CosArray)
    len = length(contents)
    arr = get(contents)
    for i = 1:len
        ref = splice!(arr, 1)
        cosstm = get_page_contents(page, ref)
        if (cosstm !== CosNull)
            push!(arr, cosstm)
        end
    end
    return merge_streams(contents)
end

get_page_contents(page::PDPageImpl, contents::CosIndirectObjectRef) =
    cosDocGetObject(page.doc.cosDoc, contents)

get_page_contents(page::PDPage, obj::CosObject) = obj

function load_page_objects(page::PDPageImpl)
    contents = pdPageGetContents(page)
    if (isnull(page.content_objects))
        page.content_objects = Nullable(PDPageObjectGroup())
    end
    return load_page_objects(page, contents)
end

load_page_objects(page::PDPageImpl, stm::CosNullType) = nothing

function load_page_objects(page::PDPageImpl, stm::CosObject)
    bufstm = decode(stm)
    try
        load_objects(get(page.content_objects), bufstm)
    finally
        close(bufstm)
    end
    return nothing
end

function load_page_objects(page::PDPageImpl, stms::CosArray)
    stm = merge_streams(stms)
    page.contents = stm
    return load_page_objects(page, stm)
end


function populate_font_encoding(page, font, fontname)
    if get(page.fums, fontname, CosNull) == CosNull
        fum = FontUnicodeMapping()
        merge_encoding!(fum, page.doc.cosDoc, font)
        page.fums[fontname] = fum
    end
end

function page_find_font(page::PDPageImpl, fontname::CosName)
    font = CosNull
    cosdoc = page.doc.cosDoc
    pgnode = page.cospage

    while font === CosNull && pgnode !== CosNull
        resref = get(pgnode, cn"Resources")
        resources = cosDocGetObject(cosdoc, resref)
        if resources !== CosNull
            fonts = cosDocGetObject(cosdoc, resources, cn"Font")
            if fonts !== CosNull
                font = cosDocGetObject(cosdoc, fonts, fontname)
                font !== CosNull && break
            end
        end
        pgnode = cosDocGetObject(cosdoc, pgnode, cn"Parent")
    end
    populate_font_encoding(page, font, fontname)
    return font
end

get_encoded_string(s::CosString, fontname::CosNullType, page::PDPage) = CDTextString(s)

get_encoded_string(s::CosString, fontname::CosName, page::PDPage) =
    get_encoded_string(s, get(page.fums, fontname, nothing))
