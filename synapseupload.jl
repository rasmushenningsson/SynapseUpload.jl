if length(ARGS)==1 && lowercase(ARGS[1]) in ["--help", "-help", "-h"]
	println("Usage:")
	println("\tjulia synapseupload.jl [folder1 folder2 ...]")
	exit(0)
end

using SynapseClient
using SynapseUploadUtils

# Implementation
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


sources = length(ARGS)>0 ? ARGS : ["."]
map!(abspath,sources)

# TODO: error checking
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

