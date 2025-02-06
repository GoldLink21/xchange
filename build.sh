if [ $# -gt 0 ]; then 
    odin build . -vet -no-entry-point -build-mode:obj
else
    odin run . -vet
fi