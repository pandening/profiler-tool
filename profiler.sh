#!/bin/bash

usage() {
    echo "Usage: $0 [action] [options] <pid>"
    echo "Polymerized Commands:"
    echo "  fg                start to profiling and get a frameGraph named flamegraph.svg"
    echo "Actions:"
    echo "  start             start profiling and return immediately"
    echo "  stop              stop profiling"
    echo "  status            print profiling status"
    echo "  list              list profiling events supported by the target JVM"
    echo "  collect           collect profile for the specified period of time"
    echo "                    and then stop (default action)"
    echo "Options:"
    echo "  -e event          profiling event: cpu|alloc|lock|cache-misses etc."
    echo "  -d duration       run profiling for <duration> seconds"
    echo "  -f filename       dump output to <filename>"
    echo "  -i interval       sampling interval in nanoseconds"
    echo "  -b bufsize        frame buffer size"
    echo "  -t                profile different threads separately"
    echo "  -o fmt[,fmt...]   output format: summary|traces|flat|collapsed|t1t|ladder"
    echo ""
    echo "<pid> is a numeric process ID of the target JVM"
    echo "      or 'jps' keyword to find running JVM automatically using jps tool"
    echo ""
    echo "Example: $0 -d 30 -f profile.fg -o collapsed 3456"
    echo "         $0 start -i 999000 jps"
    echo "         $0 stop -o summary,flat jps"
    exit 1
}

mirror_output() {
    # Mirror output from temporary file to local terminal
    if [[ $USE_TMP ]]; then
        if [[ -f $FILE ]]; then
            cat $FILE
            rm $FILE
        fi
    fi
}

check_if_terminated() {
    if ! kill -0 $PID 2> /dev/null; then
        mirror_output
        exit 0
    fi
}

# check if we have download the FlameGraph tool
check_flame_graph_tool() {
    echo "Checking if the FlameGraph tool is existed..."
    FLAME_GRAPH_PATH="tools"
    FLAME_GRAPH_NAME="FlameGraph"
    FLAME_GRAPH_GIT_CLONE_PATH="https://github.com/brendangregg/FlameGraph"
    if [ ! -x "$FLAME_GRAPH_PATH" ]; then
        echo "There is no tools path find, create it and download the tool [FlameGraph]..."
        mkdir "$FLAME_GRAPH_PATH"
        cd "$FLAME_GRAPH_PATH"
        git clone "$FLAME_GRAPH_GIT_CLONE_PATH"
        cd ../
    else 
        cd "$FLAME_GRAPH_PATH"
        if [ ! -x "$FLAME_GRAPH_NAME" ]; then
            echo "There is a tools path, but no FlameGraph path find, download it..."
            git clone "$FLAME_GRAPH_GIT_CLONE_PATH"
        fi
        cd ../
    fi
    pwd
}

# this method will wait the Polymerized command :"fg"
# and using the output file to generate a flamegraph.svg file  
# the params: 
#       [$1] -> flame graph data file path
#       [$2] -> pid of profiling jvm
#       [$3] -> color choose [java etc]
#       [$4] -> times to profiles
wait_fg_command_and_generate_flame_graph_file() {
    FLAME_GRAPH_RAW_DATA_PATH=$1
    PID=$2
    COLOR=$3
    TIMES_TO_PROFILE=$4
    FLAME_GRAPH_FILE="flamegraph."${PID}".svg"
    echo "the flame graph raw data file is:$FLAME_GRAPH_RAW_DATA_PATH time to wait:$TIMES_TO_PROFILE"

    if (( TIMES_TO_PROFILE < 1 )); then
        $TIMES_TO_PROFILE=5 #default time to wait
    fi

    while (( TIMES_TO_PROFILE-- > 0 )); do
        check_if_terminated
        sleep 1 # sleep 1 seconds
        echo "wait_fg_command_and_generate_flame_graph_file:$TIMES_TO_PROFILE"
    done    

    if [ ! -f "$FLAME_GRAPH_RAW_DATA_PATH" ]; then
        echo "The file: $FLAME_GRAPH_RAW_DATA_PATH still not exists"
    else 
        file_szie=0
        file_size=$(wc -c < "$FLAME_GRAPH_RAW_DATA_PATH")
        if [ $file_size -eq 0 ]; then 
            echo "Success to get the file: $FLAME_GRAPH_RAW_DATA_PATH, but the file size is 0"
        else 
            echo "Success to get the file: $FLAME_GRAPH_RAW_DATA_PATH, start to generate flamegraph.svg"
            check_flame_graph_tool # check the flame graph tool
            pwd # for debug
            ./tools/FlameGraph/flamegraph.pl --colors="$COLOR" "$FLAME_GRAPH_RAW_DATA_PATH" > "$FLAME_GRAPH_FILE"
            echo "output flamegraph file is:$FLAME_GRAPH_FILE"
        fi
    fi
}

jattach() {
    $JATTACH $PID load "$PROFILER" true $1 > /dev/null
    RET=$?

    # Check if jattach failed
    if [ $RET -ne 0 ]; then
        if [ $RET -eq 255 ]; then
            echo "Failed to inject profiler into $PID"
            UNAME_S=$(uname -s)
            if [ "$UNAME_S" == "Darwin" ]; then
                otool -L "$PROFILER"
            else
                ldd "$PROFILER"
            fi
        fi
        exit $RET
    fi

    mirror_output
}

function abspath() {
    UNAME_S=$(uname -s)
    if [ "$UNAME_S" == "Darwin" ]; then
        perl -MCwd -e 'print Cwd::abs_path shift' $1
    else
        readlink -f $1
    fi
}


OPTIND=1
SCRIPT_DIR=$(dirname $0)
JATTACH=$SCRIPT_DIR/build/jattach
PROFILER=$(abspath $SCRIPT_DIR/build/libasyncProfiler.so)
ACTION="collect"
EVENT="cpu"
DURATION="60"
FILE=""
USE_TMP="true"
INTERVAL=""
FRAMEBUF=""
THREADS=""
OUTPUT="summary,traces=200,flat=200"
CHECK_TOOLS="true"

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|"-?")
            usage
            ;;
        start|stop|status|list|collect|fg)
            ACTION="$1"
            ;;
        -e)
            EVENT="$2"
            shift
            ;;
        -d)
            DURATION="$2"
            shift
            ;;
        -f)
            FILE="$2"
            unset USE_TMP
            shift
            ;;
        -i)
            INTERVAL=",interval=$2"
            shift
            ;;
        -b)
            FRAMEBUF=",framebuf=$2"
            shift
            ;;
        -t)
            THREADS=",threads"
            ;;
        -o)
            OUTPUT="$2"
            shift
            ;;
        [0-9]*)
            PID="$1"
            ;;
        jps)
            # A shortcut for getting PID of a running Java application
            # -XX:+PerfDisableSharedMem prevents jps from appearing in its own list
            PID=$(jps -q -J-XX:+PerfDisableSharedMem)
            ;;
        *)
        	echo "Unrecognized option: $1"
        	usage
        	;;
    esac
    shift
done

[[ "$PID" == "" ]] && usage

# if no -f argument is given, use temporary file to transfer output to caller terminal
if [[ $USE_TMP ]]; then
    FILE=$(mktemp /tmp/async-profiler.XXXXXXXX)
fi

#if we need to check the tools
if [[ $CHECK_TOOLS ]]; then 
    check_flame_graph_tool
fi

case $ACTION in
    start)
        jattach start,event=$EVENT,file=$FILE$INTERVAL$FRAMEBUF$THREADS,$OUTPUT
        ;;
    stop)
        jattach stop,file=$FILE,$OUTPUT
        ;;
    status)
        jattach status,file=$FILE
        ;;
    list)
        jattach list,file=$FILE
        ;;
    fg)
        OUTPUT="collapsed"
        TIME_TO_PROFILE=$DURATION
        jattach start,event=$EVENT,file=$FILE$INTERVAL$FRAMEBUF$THREADS,$OUTPUT
        while (( DURATION-- > 0 )); do
            echo "DURATION:$DURATION"
            check_if_terminated
            sleep 1
        done
        jattach stop,file=$FILE,$OUTPUT 

        #wait and generate flame graph
        wait_fg_command_and_generate_flame_graph_file $FILE $PID java $TIME_TO_PROFILE
        ;;    
    collect)
        jattach start,event=$EVENT,file=$FILE$INTERVAL$FRAMEBUF$THREADS,$OUTPUT
        while (( DURATION-- > 0 )); do
            check_if_terminated
            sleep 1
        done
        jattach stop,file=$FILE,$OUTPUT
        ;;
esac
