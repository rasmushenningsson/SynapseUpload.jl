# SynapseUpload.jl
Simple uploading script for adding raw data to Synapse.

## Installation
- (install python)
- pip install synapseclient
- Pkg.install("PyCall")
- Pkg.clone("git@github.com:rasmushenningsson/SynapseClient.jl.git")
- Pkg.clone("git@github.com:rasmushenningsson/SynapseUpload.jl.git")
- put link to synapseupload in path
- (create Synapse account and login locally)

## Usage
julia synapseupload.jl [folder1 folder2 ...]
