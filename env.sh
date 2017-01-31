#!/bin/bash

proj_info() {
  echo "####### projdir: $projdir"
  echo "####### host_plat: $host_plat"
  echo "####### target_plat: $target_plat ($target_label)"
  echo "####### confscript: $configcmd"
  echo "####### buildconf: $buildconf"
  echo "####### builddir: ${builddir#$projdir/}"
  echo "####### deploydir: ${deploydir#$projdir/}"
}

_proj_set_target() {
  [[ -n "$1" && "$1" == "$target_plat" ]] && return
  unset -v target_conf_flags target_plat_prefix
  local target_to_set

  if [ -z $1 ]; then
    target_to_set=$host_plat
    target_label="default"
  else
    target_to_set=$1
    target_label="set by user"
  fi

  #TODO
  #if [[ $host_plat == $target_to_set ]]; then
    #target_to_set=$host_plat
    #configcmd=cmake
    #run=''
  #else
    case $target_to_set in
      *android*)
        configcmd='./config'
        target_conf_flags=( )
        run=''
        ;;
      *)
        echo "Unsupported target platform '${target_to_set}'!"
        return 1
        ;;
    esac
  #fi

  target_plat=$target_to_set
  _proj_set_buildconf $buildconf >/dev/null
  echo "## target_plat set to $target_plat ($target_label)"
}

ensure_dir() {
  test -d $1 || mkdir -pv $1 || return 1
}

push_dir() {
  for arg in $@; do
    case $arg in
      '-p') local f='yes';;
      '-c') local c='yes';;
      *) local d=$arg;;
    esac
  done
  [ -z $f ] || ensure_dir $d || return 1
  #[ -z $c ] || rm $d/* -rf || return 1
  pushd $d > /dev/null
}

pop_dir() { popd $1 > /dev/null; }

push_buildir() {
  [ -z $deploydir ] && return 1
  test -d $builddir || mkdir -pv $builddir || return 1
  push_dir $builddir $@ || return 1
}

push_deploydir() {
  [ -z $deploydir ] && return 1
  test -d $builddir || mkdir -pv $deploydir || return 1
  push_dir $deploydir $@ || return 1
}

p_config_opts=(
  --target
  --buildconf
  --dry
  --quiet
)
proj_config() {
  local newtarget newbuildtype
  local consolidate=1 verbose=1
  declare -a other_args
  while (( $# )); do
    case $1 in
      --target) shift && newtarget=$1;;
      --buildconf) shift && newbuildtype=$1;;
      --dry) consolidate=0;;
      --quiet) verbose=0;;
      *) other_args+=( $1 );;
    esac
    shift
  done

  [ -z $newtarget ] || _proj_set_target $newtarget || return 1
  [ -z $newbuildtype ] || _proj_set_buildconf $newbuildtype || return 1
  (( $verbose)) && proj_info

  # Commit configuration to underlying build system
  if (( $consolidate )); then
    echo
    echo "## Running configuration tool..."

    push_dir $srcdir
    perl -pi -e 's/install: all install_docs install_sw/install: install_sw/g' Makefile.org

    local config_cmd="$configcmd ${conf_flags[@]} --openssldir=${deploydir}"
    echo "Config command: [$config_cmd]" && $config_cmd
    pop_dir
  fi
}

proj_build() {
    push_dir $srcdir
    make depend
    make CALC_VERSIONS="SHLIB_COMPAT=; SHLIB_SOVER=" MAKE="make -e" all
    local r=$?
    pop_dir
    return $r
}

proj_deploy() {
  echo "## Deploying..."
  case $target_plat in
    android*)
      push_buildir
      # Gambi based on http://stackoverflow.com/a/33869277/2321647
      # to force build of "version-less" sharad objects (.so)
      mkdir -pv ${deploydir}/lib &&
        echo "place-holder make target for avoiding symlinks" >> ${deploydir}/lib/link-shared
      make SHLIB_EXT=.so install_sw && rm ${deploydir}/lib/link-shared && {
        echo "### Creating simplified android install dir..."
        local pkg="${deploydir}/../openssl/${target_plat}-${ANDROID_API}"
        [[ ! -d $pkg ]] && mkdir -pv $pkg || rm -rfv $pkg/*
        mkdir -pv ${pkg}/lib && cp -fv ${deploydir}/lib/*.so ${pkg}/lib/
        echo "### Done!"
      }
      pop_dir
      ;;
    *)
      echo "### Not supported! :("
      ;;
  esac
}

_proj_set_buildconf() {
  local conf=$1
  case $conf in
    debug | release)
      deploydir=$(_proj_deploy_dir $conf)
      builddir=$(_proj_build_dir $conf)
      exe="${builddir}/src/$(_proj_exe_name)"
      conf_flags=(
        shared
        no-ssl2
        no-ssl3
        no-comp
        no-hw
        no-engine
      )
      ;;
    *)
      echo "Unrecognized buildconf: '$conf'"
      return 1
  esac
  buildconf=$conf
  echo "## buildconf set to $buildconf"
}

_proj_build_dir() {
  #echo "$projdir/.build/${target_plat}-$1"
  echo $srcdir # no shadow building for now
}

_proj_deploy_dir() {
  echo "$projdir/.deploy/${target_plat}-$1"
}

_proj_exe_name() {
  case $target_plat in
    *Linux*) echo $exebasename;;
  esac
}

####################################################
# Alias/Bash completion stuff
####################################################

p_functions=( $(compgen -A function | grep ^proj_) )
p_all_commands=( "${p_functions[@]#proj_}" )

__simple_array_completion() {
  local arrname=$1 cur="${COMP_WORDS[COMP_CWORD]}"
  local result=( $(eval "echo \${$arrname[@]}") )
  COMPREPLY=( $(compgen -W "${result[*]}" -- ${cur}) )
}

_p_set_target_completion() {
  __simple_array_completion available_plats
}

_p_set_buildconf_completion() {
  __simple_array_completion available_buildconfs
}

_p_run_completion() {
  __simple_array_completion p_run_opts
}

_p_config_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[$(($COMP_CWORD - 1))]}"
    local result=() opt

    [[ $prev == --* ]] && opt=$prev
    if [[ -z $opt ]]; then
      result+=( "${p_config_opts[@]}" )
      COMPREPLY=( $(compgen -W "${result[*]}" -- ${cur}) )
    else
      local compfunc="_p_set_${opt#--}_completion"
      type $compfunc &>/dev/null && $compfunc
    fi
}

_config_android_crossbuild() {
  # pre-config stuff
  # FIXME supports only android for now
  export ANDROID_NDK_ROOT=${ANDROID_NDK}
  export ANDROID_API='android-18'
  export ANDROID_ARCH='arch-arm'
  export ANDROID_EABI='arm-linux-androideabi-4.9'
  source ${scriptdir}/setenv-android.sh
}

for cmd in ${p_all_commands[@]}; do
  eval "${cmd}() { proj_${cmd} \$@; }"
  compfunc="_p_${cmd}_completion"
  type $compfunc &>/dev/null &&
    eval "complete -F $compfunc $cmd"
done
unset -v cmd compfunc

#################################
#### Let'go!
#################################

scriptdir=$(dirname $BASH_SOURCE)
projdir=$(readlink -f $scriptdir)
srcdir="${scriptdir}/openssl"
exebasename='libssl.so'

host_plat="$(uname -s)-$(uname -m)"

# command options available/defaults
available_plats=( $host_plat 'android_armv7' )
available_buildconfs=( 'debug' 'release' )

default_plat=${available_plats[1]}
default_buildconf=${available_buildconfs[1]}

_config_android_crossbuild

_proj_set_target ${1:-$default_plat} >/dev/null || return 1
# TODO get this from command line option ??
_proj_set_buildconf $default_buildconf

proj_info


