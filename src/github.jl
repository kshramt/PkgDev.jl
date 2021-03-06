module GitHub

import Main, Base.Pkg.PkgError
import JSON
using Compat

const AUTH_NOTE = "Julia Package Manager"
const AUTH_DATA = Dict{Any,Any}(
    "scopes" => ["repo"],
    "note" => "$AUTH_NOTE: $(gethostname())",
    "note_url" => "http://docs.julialang.org/en/latest/manual/packages/",
)

function user()
    usr = LibGit2.getconfig("github.user", "")
    if isempty(usr) #TODO: add `config` command to Git REPL and change below info
        throw(PkgError("""
        no GitHub user name configured; please configure with:

            PkgDev.config()

        """))
    end
    return usr
end

function curl(url::AbstractString, opts::Cmd=``)
    success(`curl --version`) || throw(PkgError("using the GitHub API requires having `curl` installed"))
    out, proc = open(`curl -i -s -S $opts $url`,"r")
    head = readline(out)
    status = parse(Int,split(head,r"\s+";limit=3)[2])
    header = Dict{AbstractString,AbstractString}()
    for line in eachline(out)
        if !ismatch(r"^\s*$",line)
            (k,v) = split(line, r":\s*"; limit=2)
            header[k] = v
            continue
        end
        wait(proc); return status, header, readstring(out)
    end
    throw(PkgError("strangely formatted HTTP response"))
end
curl(url::AbstractString, data::Void, opts::Cmd=``) = curl(url,opts)
curl(url::AbstractString, data, opts::Cmd=``) =
    curl(url,`--data $(sprint(io->JSON.print(io,data))) $opts`)

function delete_token()
    tokfile = Pkg.Dir.path(".github","token")
    Base.rm(tokfile)
    info("Could not authenticate with existing token. Deleting token and trying again.")
end

readtoken(tokfile=Pkg.Dir.path(".github","token")) = isfile(tokfile) ? strip(readchomp(tokfile)) : ""

function token(user::AbstractString=user())
    tokfile = Pkg.Dir.path(".github","token")
    tok = readtoken(tokfile)
    !isempty(tok) && return tok

    info("""
Creating a personal access token for Julia Package Manager on GitHub.
\tYou will be asked to provide credentials to your GitHub account.""")
    params = merge(AUTH_DATA, Dict("fingerprint" => randstring(40)))
    status, header, content = curl("https://api.github.com/authorizations",params,`-u $user`)
    tfa = false

    # Check for two-factor authentication
    if status == 401 && get(header, "X-GitHub-OTP", "") |> x->startswith(x, "required") && isinteractive()
        tfa = true
        info("Two-factor authentication in use.  Enter auth code.  (You may have to re-enter your password.)")
        print(STDERR, "Authentication code: ")
        code = readline(STDIN) |> chomp
        status, header, content = curl("https://api.github.com/authorizations",params,`-H "X-GitHub-OTP: $code" -u $user`)
    end

    if status == 422
        error_code = JSON.parse(content)["errors"][1]["code"]
        throw(PkgError("GitHub returned validation error (422): $error_code: $(JSON.parse(content)["message"])"))
    else
        (status != 401 && status != 403) || throw(PkgError("$status: $(JSON.parse(content)["message"])"))
        tok = JSON.parse(content)["token"]
    end

    mkpath(dirname(tokfile))
    open(io->println(io,tok),tokfile,"w")
    return tok
end

function req(resource::AbstractString, data, opts::Cmd=``)
    url = "https://api.github.com/$resource"
    status, header, content = curl(url,data,`-u $(token()):x-oauth-basic $opts`)
    response = JSON.parse(content)
    status, response
end

GET(resource::AbstractString, data, opts::Cmd=``) = req(resource,data,opts)
HEAD(resource::AbstractString, data, opts::Cmd=``) = req(resource,data,`-I $opts`)
PUT(resource::AbstractString, data, opts::Cmd=``) = req(resource,data,`-X PUT $opts`)
POST(resource::AbstractString, data, opts::Cmd=``) = req(resource,data,`-X POST $opts`)
PATCH(resource::AbstractString, data, opts::Cmd=``) = req(resource,data,`-X PATCH $opts`)
DELETE(resource::AbstractString, data, opts::Cmd=``) = req(resource,data,`-X DELETE $opts`)

for m in (:GET,:HEAD,:PUT,:POST,:PATCH,:DELETE)
    @eval $m(resource::AbstractString, opts::Cmd=``) = $m(resource,nothing,opts)
end

function pushable(owner::AbstractString, repo::AbstractString, user::AbstractString=user())
    status, response = HEAD("repos/$owner/$repo")
    status == 404 && throw(PkgError("repo $owner/$repo does not exist"))
    status, response = GET("repos/$owner/$repo/collaborators/$user")
    status == 204 && return true
    status == 404 && return false
    throw(PkgError("unexpected API status code: $status – $(response["message"])"))
end

function fork(owner::AbstractString, repo::AbstractString)
    status, response = POST("repos/$owner/$repo/forks")
    if status == 401
        delete_token()
        status, response = POST("repos/$owner/$repo/forks")
    end
    status == 202 || throw(PkgError("forking $owner/$repo failed: $(response["message"])"))
    return response
end

function credentials()
    username = try user() catch "" end
    password = readtoken()
    return Nullable(LibGit2.UserPasswordCredentials(username, password))
end

end # module
