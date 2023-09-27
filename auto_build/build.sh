#!/bin/bash

# Build ASP. On any failure, ensure the "Fail" flag is set in
# $statusFile on the calling machine, otherwise the caller will wait
# forever.

# On success, copy back to the master machine the built tarball and
# set the status.

if [ "$#" -lt 4 ]; then
    echo Usage: $0 buildDir statusFile buildMachine masterMachine
    exit 1
fi

if [ -x /usr/bin/zsh ] && [ "$MY_BUILD_SHELL" = "" ]; then
    # Use zsh if available, that helps with compiling on pfe,
    # more specifically with ulmit.
    export MY_BUILD_SHELL=zsh
    exec /usr/bin/zsh $0 $*
fi

buildDir=$1
statusFile=$2
buildMachine=$3
masterMachine=$4

echo now in build.sh
echo buildDir=$buildDir
echo statusFile=$statusFile
echo buildMachine=$buildMachine
echo masterMachine=$masterMachine

cd $HOME
if [ ! -d "$buildDir" ]; then
    echo "Error: Directory: $buildDir does not exist"
    echo "Fail build_failed" > $buildDir/$statusFile
    exit 1
fi
cd $buildDir

# Set path and load utilities
source $HOME/$buildDir/auto_build/utils.sh

# Current machine
runMachine=$(machine_name)

# These are needed primarily for pfe
ulimit -s unlimited 2>/dev/null
ulimit -f unlimited 2>/dev/null
ulimit -v unlimited 2>/dev/null
ulimit -u unlimited 2>/dev/null

# rm -fv ./BaseSystem*bz2
# rm -fv ./StereoPipeline*bz2

# Set the ISIS env, needed for 'make check' in ASP. Do this only
# on the Mac, as on other platforms we lack
# all the needed ISIS data.
isMac=$(uname -s | grep Darwin)
if [ "$isMac" != "" ]; then
    isis=$(isis_file)
    if [ -f "$isis" ]; then
        . "$isis"
    else
        echo "Warning: Could not set up the ISIS environment."
    fi
fi

# Dump the environmental variables
env

# Init the status file
echo "NoTarballYet now_building" > $HOME/$buildDir/$statusFile

# The process is very different for cloudMacOS
# May need to move it to its own file
if [ "$buildMachine" = "cloudMacOS" ]; then
    echo wil do cloud
  
    # The path to the gh tool
    gh=/home/oalexan1/miniconda3/envs/gh/bin/gh
    # check if $gh exists and is executable
    if [ ! -x "$gh" ]; then
        echo "Error: Cannot find the gh tool at $gh"
        exit 1
    fi

    repo=git@github.com:NeoGeographyToolkit/StereoPipeline.git
    
    # Start a new run
    echo "Starting a new run"
    echo $gh workflow run build_test -R $repo
    $gh workflow run build_test -R $repo
    
    # Wait for 6 hours, by iterating 720 times with a pause of 30 seconds
    success=""
    for i in {0..720}; do
        echo "Waiting for the build to finish, iteration $i"
        echo "Will sleep for 30 seconds"
        sleep 30
     
        # For now just fetch the latest. Must launch and wait till it is done
        ans=$($gh run list -R $repo --workflow=build_test.yml | grep -v STATUS | head -n 1)
        echo ans is $ans
        # Extract second value from ans with awk
        completed=$(echo $ans | awk '{print $1}')
        success=$(echo $ans | awk '{print $2}')
        id=$(echo $ans | awk '{print $7}')
        echo completed is $completed
        echo success is $success
        echo id is $id
        
        if [ "$completed" != "completed" ]; then
            # It can be queued, in_progress, or completed
            echo not completed, will wait
        else
            echo completed, will break
            break
        fi
    done
    
    if [ "$success" != "success" ]; then
        echo failed
        echo "Fail build_failed" > $HOME/$buildDir/$statusFile
        exit 1
    else
        echo success    
    fi
    
    # Wipe a prior directory
    /bin/rm -rf StereoPipeline-macOS

    # Fetch the build from the cloud. I twill be in StereoPipeline-macOS
    echo Fetching the build with id $id from the cloud. 
    echo now in $(pwd)
    echo $gh run download -R $repo $id
    $gh run download -R $repo $id
    
    asp_tarball=$(ls StereoPipeline-macOS/StereoPipeline-*.tar.bz2 | head -n 1)
    echo will list
    ls StereoPipeline-macOS/*
    # Check if empty, that means it failed
    if [ "$asp_tarball" = "" ]; then
        echo "Fail build_failed" > $HOME/$buildDir/$statusFile
        exit 1
    fi
    
    # Move the build to where it is expected, then record the build name
    mkdir -p asp_tarballs
    mv $asp_tarball asp_tarballs
    asp_tarball=asp_tarballs/$(basename $asp_tarball)

    # Mark the build as finished. This must happen at the very end,
    # otherwise the parent script will take over before this script finished.
    echo "$asp_tarball build_done Success" > $HOME/$buildDir/$statusFile
    
    # Wipe the fetched directory
    /bin/rm -rf StereoPipeline-macOS
    
    echo "Finished running build.sh locally!"
    exit 0
fi
  
# Build everything, including VW and ASP. Only the packages
# whose checksum changed will get built.
echo "Building changed packages"
opt=""
if [ "$isMac" != "" ]; then
    opt="--cc=$isisEnv/bin/clang --cxx=$isisEnv/bin/clang++ --gfortran=$isisEnv/bin/gfortran"
else
    opt="--cc=$isisEnv/bin/x86_64-conda_cos6-linux-gnu-gcc --cxx=$isisEnv/bin/x86_64-conda_cos6-linux-gnu-g++ --gfortran=$isisEnv/bin/x86_64-conda_cos6-linux-gnu-gfortran"
fi

# The path to the ASP dependencies 
opt="$opt --asp-deps-dir $isisEnv"

cmd="./build.py $opt --skip-tests"
echo $cmd
eval $cmd
exitStatus=$?

echo "Build status is $exitStatus"
if [ "$exitStatus" -ne 0 ]; then
    echo "Fail build_failed" > $HOME/$buildDir/$statusFile
    exit 1
fi

# Build the documentation on the master machine
if [ "$(echo $buildMachine | grep $masterMachine)" != "" ]; then
    ./auto_build/build_doc.sh $buildDir
    exitStatus=$?
    if [ "$exitStatus" -ne 0 ]; then
        echo "Fail build_failed" > $HOME/$buildDir/$statusFile
        exit 1
    fi

    pdf_doc=$HOME/$buildDir/build_asp/build/stereopipeline/stereopipeline-git/docs/_build/latex/asp_book.pdf
    /bin/mv -fv $pdf_doc dist-add/asp_book.pdf
fi

# Dump the ASP version
versionFile=$(version_file $buildMachine)
find_version $versionFile
echo "Saving the ASP version ($(cat $versionFile)) to file: $versionFile"

# Make sure all maintainers can access the files.
# Turn this off as there is only one maintainer,
# and they fail on some machines
#chown -R  :ar-gg-ti-asp-maintain $HOME/$buildDir
#chmod -R g+rw $HOME/$buildDir

echo "Packaging ASP."
./make-dist.py last-completed-run/install --asp-deps-dir $isisEnv --python-env $pythonEnv

if [ "$?" -ne 0 ]; then
    echo "Fail build_failed" > $HOME/$buildDir/$statusFile
    exit 1
fi

# Copy the build to asp_tarballs
echo "Moving packaged ASP to directory asp_tarballs"
asp_tarball=$(ls -trd StereoPipeline*bz2 | grep -i -v debug | tail -n 1)
if [ "$asp_tarball" = "" ]; then
    echo "Fail build_failed" > $HOME/$buildDir/$statusFile
    exit 1
fi
mkdir -p asp_tarballs
mv $asp_tarball asp_tarballs
asp_tarball=asp_tarballs/$asp_tarball

# Wipe old builds on the build machine
echo "Cleaning old builds..."
numKeep=8
if [ "$(echo $buildMachine | grep $masterMachine)" != "" ]; then
    numKeep=24 # keep more builds on master machine
fi
$HOME/$buildDir/auto_build/rm_old.sh $HOME/$buildDir/asp_tarballs $numKeep

# rm -f StereoPipeline*debug.tar.bz2

# Mark the build as finished. This must happen at the very end,
# otherwise the parent script will take over before this script finished.
echo "$asp_tarball build_done Success" > $HOME/$buildDir/$statusFile

# Last time make sure the permissions are right
# Turn this off as these fail on some machines
#chown -R  :ar-gg-ti-asp-maintain $HOME/$buildDir
#chmod -R g+rw $HOME/$buildDir

echo "Finished running build.sh locally!"
