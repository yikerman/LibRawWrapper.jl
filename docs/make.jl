using LibRawWrapper
using Documenter

DocMeta.setdocmeta!(LibRawWrapper, :DocTestSetup, :(using LibRawWrapper); recursive = true)

# Documenter checks inclusion of existing docstrings; also require every managed
# export to have one. Generated C ABI exports are documented by upstream LibRaw.
highlevel_exports = filter(names(LibRawWrapper)) do name
    name != :LibRawWrapper && !startswith(string(name), "libraw_")
end
docstrings = Base.Docs.meta(LibRawWrapper)
undocumented = filter(highlevel_exports) do name
    !haskey(docstrings, Base.Docs.Binding(LibRawWrapper, name))
end
isempty(undocumented) || error("Missing high-level docstrings: $(join(undocumented, ", "))")

makedocs(
    sitename = "LibRawWrapper.jl",
    modules = [LibRawWrapper],
    format = Documenter.HTML(
        prettyurls = false,
        edit_link = nothing,
        repolink = "https://github.com/yikerman/LibRawWrapper.jl",
    ),
    checkdocs = :exports,
    pages = [
        "Home" => "index.md",
        "Tutorial" => "tutorial.md",
        "How-to guides" => "how-to.md",
        "Reference" => "api.md",
        "Explanation" => "explanation.md",
    ],
)
