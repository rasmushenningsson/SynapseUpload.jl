module SynapseUploadUtils

export FolderInfo,
       listfiles,
       confirmupload,
       uploadfolder


using SynapseClient
import SynapseClient: AbstractEntity, Project, Folder, File, Activity


type FolderInfo
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


function listfiles(path::AbstractString)
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
			# println("folder: $file")
			push!(folderInfo.folders, listfiles(fullFilePath))
		else
			# println("file: $file")
			push!(folderInfo.files, file)
		end
	end

	folderInfo
end



function getchildbyname(syn, parentID::AbstractString, child::AbstractString)
	results = chunkedquery(syn, "select id from entity where entity.parentId=='$parentID' and entity.name=='$child'")

	# # if 0 results, return "",
	# # if 1 result, return it
	# # if 2 results, error

	res = ""
	for (i,r) in enumerate(results)
		i>1 && error("Unexpected error, multiple children with the same name.")
		res = r["entity.id"]
	end
	res::ASCIIString
end
getchildbyname(syn, parent::AbstractEntity, child::AbstractString) = getchildbyname(syn, parent["id"],child)


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
		entity = get(syn,id)
		name = entity["name"]

		typeof(entity) <: Folder || return name # i.e. go upwards until we find the parent project
		return string(fullsynapsepath(syn,entity["parentId"]), '/', name)
	end
	return "[UNKNOWN]"
end


function confirmupload(syn::Synapse, parentFolderID::AbstractString, fi::FolderInfo)
	synapsePath = fullsynapsepath(syn, parentFolderID);

	child = getchildbyname(syn, parentFolderID, fi.name)
	if !isempty(child)
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

	askforconfirmation("Upload to \"$synapsePath\"?")
end


function _uploadfolder(syn::Synapse, parentID::AbstractString, fi::FolderInfo, exec::AbstractString)
	folder = getchildbyname(syn, parentID, fi.name)
	if isempty(folder)
		# create folder
		folder = Folder(fi.name, parent=parentID)
		act = Activity(name="Uploaded folder")
		isempty(exec) || executed(act,exec)
		folder = store(syn,folder,activity=act)
	end

	annot = getannotations(syn, folder)
	annot["uploading"] = "In progress"
	setannotations(syn, folder, annot)

	for filename in fi.files
		# TODO: set contentType?
		file = File(path=joinpath(fi.path,filename), name=filename, parent=folder)
		act = Activity(name="Uploaded file")
		isempty(exec) || executed(act,exec)
		file = store(syn,file,activity=act)
	end

	for subfolder in fi.folders	
		_uploadfolder(syn,folder,subfolder,exec)
	end

	annot = getannotations(syn, folder)
	annot["uploading"] = "Finished"
	setannotations(syn, folder, annot)
end

_uploadfolder(syn::Synapse, parent::Folder, fi::FolderInfo, exec::AbstractString) = _uploadfolder(syn, parent["id"], fi, exec)


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
function printuploadusage()
	println("Usage:")
	println("\tjulia synapseupload.jl [options] folder1 [folder2 ...]")
	println("Options:")
	println("\t-h, --help, -help\tShow help message")
end
function uploadfolder(ARGS)
	if length(ARGS)==0 || any(x->lowercase(x)∈["--help","-help","-h"],ARGS)
		printuploadusage()
		length(ARGS)==0 && println("Error: At least one folder must be specified.")
		return
	end

	sources = copy(ARGS)
	map!(abspath,sources)

	syn = SynapseClient.login()

	parentFolderID = "syn6177609"

	# prepare 
	folders = Array{FolderInfo,1}(length(sources))
	map!(listfiles, folders, sources)

	# check that it is ok to upload each folder
	for fi in folders
		confirmupload(syn, parentFolderID, fi) || exit(0) # error("User abort")
	end

	# upload each folder
	for fi in folders
		uploadfolder(syn, parentFolderID, fi, executed="https://github.com/rasmushenningsson/SynapseUpload.jl/blob/master/synapseupload.jl")
	end
end




end
