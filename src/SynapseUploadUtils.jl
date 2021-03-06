module SynapseUploadUtils

export FolderInfo,
       listfiles,
       confirmupload,
       uploadfolder,
       copyfolder


using SynapseClient
import SynapseClient: AbstractEntity, Project, Folder, File, Activity

using ArgParse
using Printf


struct FolderInfo
	path
	name
	files::Array{AbstractString,1}
	folders::Array{FolderInfo,1}
end
FolderInfo(path,name) = FolderInfo(path,name,[],[])


function describefolder!(res::Dict{AbstractString,Int}, fi::FolderInfo)
	totalSize = 0
	nbrFolders = 1
	for file in fi.files
		k = splitext(file)[2]
		res[k] = get(res,k,0)+1
		totalSize += filesize(joinpath(fi.path,file))
	end
	for folder in fi.folders
		nf,ts = describefolder!(res,folder)
		nbrFolders += nf
		totalSize += ts
	end
	nbrFolders, totalSize
end

function describefolder(fi::FolderInfo)
	res = Dict{AbstractString,Int}()
	nbrFolders, totalSize = describefolder!(res,fi)
	nbrFolders, totalSize, res
end


function listfiles(path::AbstractString; excludeFiles=[], excludeFolders=[])
	splitPath = split(path, ['/','\\'])
	while isempty(splitPath[end])
		pop!(splitPath)
	end
	isempty(splitPath) && error("\"$path\" is not a valid path")
	name = splitPath[end]


	folderInfo = FolderInfo(path, name)

	for file in readdir(path)
		isempty(file) && continue
		file[1] == '.' && continue

		fullFilePath = joinpath(path, file)
		if isdir(fullFilePath)
			any(r->ismatch(r,file), excludeFolders) && continue
			# println("folder: $file")
			push!(folderInfo.folders, listfiles(fullFilePath, excludeFiles=excludeFiles, excludeFolders=excludeFolders))
		else
			any(r->ismatch(r,file), excludeFiles) && continue
			filesize(fullFilePath)==0 && continue # Synapse doesn't allow uploading of empty files
			# println("file: $file")
			push!(folderInfo.files, file)
		end
	end

	folderInfo
end



function getchildbyname(syn, parentID::AbstractString, child::AbstractString)::String
    # if 0 results, return "",
    # if 1 result, return it
    # if 2 results, error

    res = ""
    for c in getchildren(syn, parentID)
        if get(c,"name",nothing) == child
            @assert isempty(res) "Unexpected error, multiple children with the same name."
            res = c["id"]
        end
    end
    res
end
getchildbyname(syn, parent::AbstractEntity, child::AbstractString) = getchildbyname(syn, parent.id,child)
getchildbyname(syn, parent, args::AbstractString...) = getchildbyname(syn,getchildbyname(syn, parent, args[1]),args[2:end]...)


function retrystore(syn::Synapse, args...; kwargs...)
	delays = Int[5, 30, 60]
	i = 0 # how many times did we fail?
	while true
		try
			return store(syn, args...; kwargs...)
		catch ex
			i += 1
			if i>length(delays)
				println("Synapse store failed. Aborting.")
				rethrow(ex)
			end

			println("Synapse store failed. Waiting $(delays[i])s before trying again.")
			sleep(delays[i])
		end
	end
end



function askforconfirmation(str::AbstractString)
	while true
		println(str, " (y/n)")
		response = strip(readline())
		lowercase(response) in ["y","yes"] && return true
		lowercase(response) in ["n","no"] && return false
	end
end

function nbrbytes2string(x::Integer)
	x < 1024 && return string(x, " bytes")
	y = Float64(x)/1024
	y < 1024 && return @sprintf("%.1f KB", y)
	y /= 1024
	y < 1024 && return @sprintf("%.1f MB", y)
	y /= 1024
	y < 1024 && return @sprintf("%.1f GB", y)
	y /= 1024
	@sprintf("%.1f TB", y)
end

function fullsynapsepath(syn::Synapse, id::AbstractString)
	try
		entity = get(syn, id, downloadFile=false)
		name = entity.name

		typeof(entity) <: Folder || return name # i.e. go upwards until we find the parent project
		return string(fullsynapsepath(syn,entity.parentId), '/', name)
	catch
	end
	return "[UNKNOWN]"
end


function confirmupload(syn::Synapse, parentFolderID::AbstractString, fi::FolderInfo; askForConfirmation=true)
	synapsePath = fullsynapsepath(syn, parentFolderID)

	child = getchildbyname(syn, parentFolderID, fi.name)
	if askForConfirmation && !isempty(child)
		askforconfirmation("Folder \"$(fi.name)\" already exists in \"$synapsePath\", continue?") || return false
	end

	nbrFolders, totalSize, desc = describefolder(fi)

	println("--- Summary for $(fi.name) ---")
	println("Number of folders: $nbrFolders")
	println("Number of files:")
	for (k,v) in desc
		println("\t$k: $v")
	end
	println("Total size: ", nbrbytes2string(totalSize))

	if askForConfirmation
		askforconfirmation("Upload to \"$synapsePath\"?") || return false
	end
	true
end


function _uploadfolder(syn::Synapse, parentID::AbstractString, fi::FolderInfo, exec::AbstractString)
	folder = getchildbyname(syn, parentID, fi.name)
	if isempty(folder)
		# create folder
		folder = Folder(fi.name, parent=parentID)
		act = Activity(name="Uploaded folder")
		isempty(exec) || executed(act,exec)
		folder = retrystore(syn,folder,activity=act)
	end

	annot = getannotations(syn, folder)
	annot.uploading = "In progress"
	setannotations(syn, folder, annot)

	for filename in fi.files
		# TODO: set contentType?
		file = File(path=joinpath(fi.path,filename), name=filename, parent=folder)
		act = Activity(name="Uploaded file")
		isempty(exec) || executed(act,exec)
		file = retrystore(syn,file,activity=act)
	end

	for subfolder in fi.folders	
		_uploadfolder(syn,folder,subfolder,exec)
	end

	annot = getannotations(syn, folder)
	annot.uploading = "Finished"
	setannotations(syn, folder, annot)
end

_uploadfolder(syn::Synapse, parent::Folder, fi::FolderInfo, exec::AbstractString) = _uploadfolder(syn, parent.id, fi, exec)


function uploadfolder(syn::Synapse, parentFolderID::AbstractString, fi::FolderInfo; executed="")
	_uploadfolder(syn,parentFolderID,fi,executed)
end




# Upload folder
# 	1. Identify all folders and files recursively.
# 		Ignore hidden files/folders.
# 		Ignore files/folders starting with ".".
# 	2. Ask for confirmation to continue if folder already exists in Synapse.
# 	3. Show summary of what will be uploaded:
# 		Name of folder to be uploaded.
# 		Nbr of folders.
# 		Nbr of files with different file endings.
# 		Total size.
# 	4. Ask for confirmation to continue.
# 	5. Create the folder specified in "Your Project/Your Folder".
# 	6. Add annotation that upload is in progress
# 	7. Upload files.
# 		Create subfolders as needed. (Thus, if the upload stops, we will see how far it got.)
# 	8. Add annotation that upload finished.

function parse_uploadfolder_commandline(ARGS)
    s = ArgParseSettings()

    @add_arg_table! s begin
        "--yes", "-y"
            help = "Upload without asking for confirmation"
            action = :store_true
        "--parent", "-p"
        	help = "Parent folder (synapse ID)"
            arg_type = UTF8String
        	default = UTF8String("syn6177609")
        "--excludefile", "-e"
            help = "Exclude files matching pattern"
            arg_type = Regex
            action = :append_arg 
        "--excludefolder", "-x"
            help = "Exclude folders matching pattern"
            arg_type = Regex
            action = :append_arg 
        "folders"
            help = "Folders to upload"
            nargs = '*'
            arg_type = UTF8String
            #action = :append_arg 
            required = true
    end

    return parse_args(ARGS, s)
end

function uploadfolder(ARGS)
	parsedArgs = parse_uploadfolder_commandline(ARGS)
	askForConfirmation = !parsedArgs["yes"]
	sources = parsedArgs["folders"]

	excludeFiles = parsedArgs["excludefile"]
	excludeFolders = parsedArgs["excludefolder"]

	parentFolderID = parsedArgs["parent"]


	map!(abspath,sources)

	syn = SynapseClient.login()

	# prepare 
	folders = Array{FolderInfo,1}(length(sources))
	map!( s->listfiles(s,excludeFiles=excludeFiles,excludeFolders=excludeFolders), folders, sources)

	# check that it is ok to upload each folder
	for fi in folders
		confirmupload(syn, parentFolderID, fi, askForConfirmation=askForConfirmation) || exit(0) # error("User abort")
	end

	# upload each folder
	for fi in folders
		uploadfolder(syn, parentFolderID, fi, executed="https://github.com/rasmushenningsson/SynapseUpload.jl/blob/master/synapseupload.jl")
	end
end





struct FileCopyInfo
	sourceID::AbstractString
	name::AbstractString
	# some folder info is needed for flatten=false
end



function listsynapsefiles!(syn::Synapse, list::Vector{FileCopyInfo}, parentID::AbstractString; recursive=true)
    for c in getchildren(syn, parentID)
		id = c["id"]
		entity = get(syn, id, downloadFile=false)

		if typeof(entity) == File
			push!(list, FileCopyInfo(id, entity.name))
		elseif typeof(entity) == Folder && recursive
			listsynapsefiles!(syn, list, id, recursive=recursive)
		end
    end
    list

	# results = chunkedquery(syn, "select id from entity where entity.parentId=='$parentID'")
	# for r in results
	# 	id = r["entity.id"]
	# 	entity = get(syn, id, downloadFile=false)

	# 	if typeof(entity) == File
	# 		push!(list, FileCopyInfo(id, entity["name"]))
	# 	elseif typeof(entity) == Folder && recursive
	# 		listsynapsefiles!(syn, list, id, recursive=recursive)
	# 	end
	# end
	# list
end

function listsynapsefiles(syn::Synapse,parentID::AbstractString; recursive=true)
	list = Array{FileCopyInfo,1}()
	listsynapsefiles!(syn, list, parentID, recursive=recursive)
end


function matchany(names::Array{T}, patterns::Array{Regex,1}) where {T<:AbstractString}
	Bool[any(pattern->match(pattern,name)!=nothing, patterns) for name in names]
end

function performcopy(syn::Synapse, list::Array{FileCopyInfo,1}, destinationID::AbstractString, exec::AbstractString)
	profile = getuserprofile(syn)

	for f in list
		file = get(syn, f.sourceID, downloadFile=false)
		@assert typeof(file)==File

		act = Activity(name="Copied file", used=file)
		isempty(exec) || executed(act,exec)


		local newFile

		if profile.ownerId == file.createdBy # no need to copy if the file has the same creator
	        newFile = File(name=file.name, parentId=destinationID)
	        newFile.dataFileHandleId = file.dataFileHandleId
		else # fallback to copy
            file = get(syn,f.sourceID,downloadFile=true) # download file
            newFile = File(path=file.path, name=file.name, parentId=destinationID)
		end
		retrystore(syn,newFile,activity=act)
	end
end


function copyfolder(syn::Synapse, folderName::AbstractString, parentID::AbstractString, 
	                destinationParentID::AbstractString, patterns::Array{Regex,1}; 
	                destinationName::AbstractString="", flatten=true, askForConfirmation=true, 
	                localScript="", externalScript="")
	flatten == true || error("Only flatten=true supported at the moment.")
	!isempty(localScript) && !isempty(externalScript) && error("Only one of localScript and externalScript can be specified.")

	if askForConfirmation && isempty(localScript) && isempty(externalScript)
		askforconfirmation("Please consider specifying localScript or externalScript, continue anyway?") || return false
	end

	destinationName = isempty(destinationName) ? folderName : destinationName


	synapsePath = fullsynapsepath(syn, destinationParentID)
	localScriptName = "copy_$(destinationName).jl" # only used if localScript is set

	if askForConfirmation
		destinationID = getchildbyname(syn, destinationParentID, destinationName)
		if !isempty(destinationID)
			askforconfirmation("Folder \"$(destinationName)\" already exists in \"$synapsePath\", continue?") || return false
		end
	end




	sourceFolderID = getchildbyname(syn,parentID,folderName)
	sourceFolder = get(syn,sourceFolderID,downloadFile=false)
	@assert typeof(sourceFolder)==Folder "Source should be a folder."


	list = listsynapsefiles(syn, sourceFolderID, recursive=true)
	mask = matchany(map(x->x.name,list), patterns)
	skipped = list[.!mask]
	list = list[mask] # only keep files with names matching at least one of the patterns

	if askForConfirmation
		println("--- Summary for $destinationName ---")
		println("-Skipped-")
		for f in skipped
			println("\t$(f.name)")
		end

		println("-Uploading-")
		for f in list
			println("\t$(f.name)")
		end
		isempty(localScript) || (fn = splitdir(localScript)[2]; println("Local script \"$fn\" will be uploaded to \"$synapsePath/$localScriptName\"."))
		isempty(externalScript) || println("External script: \"$externalScript\" is used for provenance.")
		askforconfirmation("Copy files to \"$synapsePath\"?") || return false
	end

	if flatten
		names = map(x->x.name,list)
		length(names) != length(unique(names)) && error("Could not flatten file structure due to name collisions.")
	end

	# create destination folder
	destFolder = Folder(name=destinationName,parentId=destinationParentID)
	destFolder = retrystore(syn, destFolder)


	# setup executed
	executed = ""
	if !isempty(localScript)
		# upload script and set executed as synapse id
		
		scriptFile = File(path=localScript, name=localScriptName, parentId=destinationParentID)

		# Had to remove this line since "FileNameOverride" is deprecated. It doesn't break anything, but if the script is downloaded, it will use the old filename which is annoying.
		#scriptFile["fileNameOverride"] = localScriptName # standardize the script file name (i.e. use same name as for uploaded folder)

		scriptFile = retrystore(syn, scriptFile)
		executed = scriptFile.id
	elseif !isempty(externalScript) # just refer to external script
		executed = externalScript
	end
	


	performcopy(syn,list,destFolder.id, executed) # copy files
	true
end

copyfolder(syn::Synapse, folderName::AbstractString, parentID::AbstractString, destinationParentID::AbstractString, pattern::Regex; kwargs...) = 
	copyfolder(syn, folderName, parentID, destinationParentID, [pattern]; kwargs...)
copyfolder(syn::Synapse, folderName::AbstractString, parentID::AbstractString, destinationParentID::AbstractString, patterns::Array{AbstractString,1}; kwargs...) = 
	copyfolder(syn, folderName, parentID, destinationParentID, map(Regex,pattern); kwargs...)
copyfolder(syn::Synapse, folderName::AbstractString, parentID::AbstractString, destinationParentID::AbstractString, pattern::AbstractString; kwargs...) = 
	copyfolder(syn, folderName, parentID, destinationParentID, Regex(pattern); kwargs...)





end
