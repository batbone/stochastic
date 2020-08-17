function tsendall() {
    dirs=( "$@" )
    (( $#dirs == 0 )) && return 1
    tlg-file-captioned ${^dirs}/**/(all|timeseries).(mp4|png)(N)
}
function ani() {
    imgdirs2vid "${^@}"/all
}
function ani-ts() {
    ani "$@"
    tsendall "$@"
    bello
}
function makie-clean() {
    ## Beware of using this when running multiple instances of the model. The incomplete data will get deleted, too.
    # rm -r ~/Base/_Code/uni/stochastic/makiePlots/**/all(/)
    # rm ~/Base/_Code/uni/stochastic/makiePlots/**/log.txt
}
function makp() {
    z makiePlots ; fnswap printz-quoted reval onlc cd ; cd all && mpv-imgseq
}
function makt() {
    z makiePlots ; fnswap printz-quoted reval onlc cd ; imgcat timeseries.png
}
function tlg-clean-copied() {
    local text="$*"
    if [[ "$text" =~ '\[[^]]*\]\s*((.|\n)*)' ]] ; then
       text="$match[1]"
    fi
    print -nr -- "$text"
}
function tlg-clean-paste() {
    tlg-clean-copied "$(pbpaste)"
}
function makpl() {
    local d="$HOME/tmp/garden/$(bottomdir "$(tlg-clean-paste)")"

    less "$d/log.txt"
}
