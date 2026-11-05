# The end-to-end program: plain Downloads calls, nothing Wasm-specific.
module FetchProg
using Downloads

say(xs...) = (println(Core.stdout, xs...); nothing)
base() = get(ENV, "FETCH_BASE", "http://127.0.0.1:8765")
outdir() = get(ENV, "FETCH_OUT", tempdir())
hdr(r::Downloads.Response, k::String) = something(get(Dict(r.headers), k, nothing), "-")
clean(s::String) = replace(s, base() => "BASE")

f() = String(take!(Downloads.download(base() * "/hello.txt", IOBuffer())))

function main()::Int32
    # 1. the task's f(): a body to an IOBuffer
    say("T1 ", f())
    # 2. a 3 MiB body to a file
    dest = joinpath(outdir(), "blob.bin")
    p = Downloads.download(base() * "/blob.bin", dest)
    say("T2 ", p == dest, " ", filesize(p))
    # 3. request: a redirect, a custom header, the response's fields
    buf = IOBuffer()
    r = Downloads.request(base() * "/redirect"; output = buf, headers = ["X-Probe" => "wasmhost"])
    if r isa Downloads.Response
        say("T3 ", r.proto === nothing ? "-" : r.proto, " ", r.status, " ", clean(r.url), " [", r.message, "] ",
            hdr(r, "content-type"), " ", hdr(r, "x-served-by"))
        say("T3 body ", String(take!(buf)))
    end
    # 4. HEAD (no output)
    r = Downloads.request(base() * "/blob.bin")
    r isa Downloads.Response && say("T4 ", r.status, " ", hdr(r, "content-length"))
    # 5. a POST with a body from an IOBuffer
    buf = IOBuffer()
    r = Downloads.request(base() * "/echo-body"; method = "POST", input = IOBuffer("payload-123"), output = buf)
    r isa Downloads.Response && say("T5 ", r.status, " ", String(take!(buf)))
    # 6. download of a 404: RequestError with code 0
    try
        Downloads.download(base() * "/missing", IOBuffer())
        say("T6 no error")
    catch e
        e isa Downloads.RequestError ? say("T6 RequestError code=", e.code, " status=", e.response.status,
                                           " [", e.response.message, "] ", clean(e.url)) : say("T6 other error")
    end
    # 7. connection refused: RequestError with a curl code, status 0
    try
        Downloads.download("http://127.0.0.1:39917/nothing", IOBuffer())
        say("T7 no error")
    catch e
        e isa Downloads.RequestError ? say("T7 RequestError code=", e.code, " status=", e.response.status) :
                                       say("T7 other error")
    end
    # 8. request(throw = false) returns the error
    r = Downloads.request("http://127.0.0.1:39917/nothing"; throw = false)
    say("T8 ", r isa Downloads.RequestError ? string("RequestError code=", r.code) : "Response")
    # 9. an explicit Downloader with an easy_hook
    d = Downloads.Downloader()
    d.easy_hook = (easy, info) -> nothing
    buf = IOBuffer()
    r = Downloads.request(base() * "/hello.txt"; output = buf, downloader = d)
    r isa Downloads.Response && say("T9 ", r.status, " ", String(take!(buf)))
    # 10. as Pkg's PlatformEngines.download calls it: progress (total, now) and an interrupt event
    seen = Ref(0)
    buf = IOBuffer()
    r = Downloads.request(base() * "/blob.bin"; output = buf, progress = (t, n) -> (seen[] = n; nothing),
                          interrupt = Base.Event())
    r isa Downloads.Response && say("T10 ", r.status, " ", length(take!(buf)), " progress now=", seen[])
    return Int32(0)
end
end
