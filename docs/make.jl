using LibRawWrapper
using Documenter

makedocs(
    sitename = "LibRawWrapper.jl",
    modules = [LibRawWrapper],
    format = Documenter.HTML(
        prettyurls = false,
        edit_link = nothing,
        repolink = "https://github.com/yikerman/LibRawWrapper.jl",
    ),
    warnonly = [:missing_docs],
    pages = ["Home" => "index.md", "API Reference" => "api.md"],
)
