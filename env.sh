# Globals
declare -a phasesArray
curPhase=""
buildDir=""
outputDirs=""

# Utility functions

# BIG FAT WARNING! The 'set -e' functionality is very broken when used in conditionals:
# foo() { false; echo "shouldn't be reached" }
# (set -e; foo) || echo 'failed'
#
# In the above, _both_ echos fire, because 'set -e' is inhibited, even in subshells!
runPhase() {
    local phase=$1
    echo "Running phase '$phase'..."

    # Run in a subshell so 'set -e' doesn't kill this shell...
    (
        set -e
        # Evaluate the variable named $phase if it exists, otherwise the
        # function named $phase. Copy-pasted from pkgs/stdenv/generic/setup.sh
        eval "${!phase:-$phase}"

        # Since we are in a subshell, we need this hack to propagate our
        # environment to the parent shell. Use 'declare -g' since otherwise
        # the variables are only local to this function.
        typeset -p | sed -e 's/^declare/declare -g/' > /tmp/vars.$$
    )
    if [ $? = 1 ]; then
        echo "Phase '$1' failed."
        return 1
    else
        source /tmp/vars.$$ 2>/dev/null
        rm -rf /tmp/vars.$$
    fi
}

doUnpack() {
    runPhase unpackPhase
    cd "${sourceRoot:-.}"
}

safeRemove() {
    echo -n "Do you want to delete these directories: $@? [y/N] "
    read r
    if [ "$r" = y -o "$r" = Y ]; then
        rm -rf "$@"
    else
        return 1
    fi
}

indexOfPhase() {
    for i in "${!phasesArray[@]}"; do 
        if [ "${phasesArray[$i]}" = "$1" ]; then
            echo $i
            return
        fi
    done
    echo "-1"
    return 1
}

getNextPhase() {
    local i=$(indexOfPhase "$curPhase")
    (( i++ ))
    echo "${phasesArray[$i]}"
}

# Commands
nd-after() {
    "nd-until" "$1"
    if [ $? = 0 ]; then
        nd-step
    else
        return 1
    fi
}

nd-goto() {
    local targetIndex=$(indexOfPhase "$1")
    if [ "$targetIndex" = -1 ]; then
        echo "Phase '$1' doesn't exist."
        return 1
    fi
    curPhase="$1"
}

nd-installclean() {
    safeRemove "$outputDirs" || return
    echo "Wiped output paths: $outputDirs."
}

nd-reset() {
    safeRemove "$buildDir" || return
    mkdir -p "$buildDir"
    echo "Wiped and recreated $buildDir"
    cd "$buildDir"
    doUnpack
}

nd-restart() {
    curPhase="${phasesArray[0]}"
    #echo "'$curPhase' is the next phase to run."
}

nd-run() {
    "nd-until" "__END__"
}

nd-step() {
    if [ "$curPhase" = "__END__" ]; then
        echo "All build phases are already executed."
    fi
    runPhase "$curPhase"
    if [ $? = 0 ]; then
        curPhase=$(getNextPhase);
    else
        return 1
    fi
}

nd-until() {
    local curIndex=$(indexOfPhase "$curPhase")
    local targetIndex=$(indexOfPhase "$1")
    if [ "$targetIndex" = -1 ]; then
        echo "Phase '$1' doesn't exist."
        return 1
    elif [ "$targetIndex" -lt "$curIndex" ]; then
        echo "Phase '$1' precedes current phase '$curPhase'."
        return 1
    fi

    while [ "$curPhase" != "$1" ]; do
        nd-step
        if [ $? != 0 ]; then break; fi
    done
}

##### Interactive script starts here
buildDir=$(pwd)
outDirBase=${buildDir/nds-build/nds-install}

oldOut="$out"
for output in $outputs; do
    if [ "$output" = out ]; then
        declare -g "$output=$outDirBase"
    else
        declare -g "$output=$outDirBase-$output"
    fi
    outputDirs="$outputDirs ${!output}"
done

if [ "$prefix" = "$oldOut" ]; then
    prefix="$out"
fi

set +e

# Copy-pasta from pkgs/stdenv/generic/setup.sh
if [ -z "$phases" ]; then
    phases="$prePhases unpackPhase patchPhase $preConfigurePhases \
        configurePhase $preBuildPhases buildPhase checkPhase \
        $preInstallPhases installPhase $preFixupPhases fixupPhase installCheckPhase \
        $preDistPhases distPhase $postPhases";
fi

for phase in $phases; do
    # Ignore certain phases, copy-pasted from pkgs/stdenv/generic/setup.sh
    if [ "$phase" = buildPhase -a -n "$dontBuild" ]; then continue; fi
    if [ "$phase" = checkPhase -a -z "$doCheck" ]; then continue; fi
    if [ "$phase" = installPhase -a -n "$dontInstall" ]; then continue; fi
    if [ "$phase" = fixupPhase -a -n "$dontFixup" ]; then continue; fi
    if [ "$phase" = installCheckPhase -a -z "$doInstallCheck" ]; then continue; fi
    if [ "$phase" = distPhase -a -z "$doDist" ]; then continue; fi

    # We special case unpackPhase
    if [ "$phase" = unpackPhase ]; then
        if [ "${#phasesArray[@]}" != 0 ]; then
            echo "Don't know how to handle pkg without unpackPhase as the first"
            exit 1
        fi
        hasUnpackPhase=1
        continue
    fi
    phasesArray+=("$phase")
done

doUnpack

# Include next phase name in prompt
PS1="${PS1/nix-shell/nix-shell(\$curPhase)}"

echo "Phases to run: ${phasesArray[@]}"
phasesArray+=("__END__")
nd-restart
