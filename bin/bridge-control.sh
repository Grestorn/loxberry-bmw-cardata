#!/bin/bash
#
# BMW CarData Bridge Control Script
# Controls the bmw-cardata-bridge daemon
#

SCRIPT_DIR="REPLACELBPBINDIR"
DATA_DIR="REPLACELBPDATADIR"
DAEMON="$SCRIPT_DIR/bmw-cardata-bridge.pl"
PID_FILE="$DATA_DIR/bridge.pid"
LOG_FILE="REPLACELBPLOGDIR/bridge.log"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Functions
get_pid() {
    if [ -f "$PID_FILE" ]; then
        cat "$PID_FILE"
    fi
}

is_running() {
    local pid=$(get_pid)
    if [ -n "$pid" ]; then
        if ps -p "$pid" > /dev/null 2>&1; then
            return 0
        else
            # Stale PID file
            rm -f "$PID_FILE"
            return 1
        fi
    fi
    return 1
}

start() {
    if is_running; then
        echo "Bridge is already running (PID $(get_pid))"
        return 1
    fi

    echo "Starting BMW CarData Bridge..."
    perl "$DAEMON" --daemon

    # Wait a moment and check if started
    sleep 2
    if is_running; then
        echo "Bridge started successfully (PID $(get_pid))"
        return 0
    else
        echo "Failed to start bridge. Check log: $LOG_FILE"
        return 1
    fi
}

stop() {
    if ! is_running; then
        echo "Bridge is not running"
        return 0
    fi

    local pid=$(get_pid)
    echo "Stopping BMW CarData Bridge (PID $pid)..."

    kill -TERM "$pid"

    # Wait for graceful shutdown
    local count=0
    while is_running && [ $count -lt 10 ]; do
        sleep 1
        count=$((count + 1))
    done

    if is_running; then
        echo "Bridge did not stop gracefully, forcing..."
        kill -KILL "$pid"
        sleep 1
    fi

    rm -f "$PID_FILE"
    echo "Bridge stopped"
    return 0
}

restart() {
    echo "Restarting BMW CarData Bridge..."
    stop
    sleep 2
    start
}

reload() {
    if ! is_running; then
        echo "Bridge is not running, cannot reload"
        return 1
    fi

    local pid=$(get_pid)
    echo "Reloading configuration (PID $pid)..."
    kill -HUP "$pid"
    echo "Configuration reload signal sent"
    return 0
}

status() {
    if is_running; then
        local pid=$(get_pid)
        echo "BMW CarData Bridge is running (PID $pid)"

        # Show last log lines
        if [ -f "$LOG_FILE" ]; then
            echo ""
            echo "Last 10 log entries:"
            tail -10 "$LOG_FILE"
        fi
        return 0
    else
        echo "BMW CarData Bridge is not running"
        return 1
    fi
}

logs() {
    if [ -f "$LOG_FILE" ]; then
        tail -f "$LOG_FILE"
    else
        echo "Log file not found: $LOG_FILE"
        return 1
    fi
}

# Main
case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        restart
        ;;
    reload)
        reload
        ;;
    status)
        status
        ;;
    logs)
        logs
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|reload|status|logs}"
        echo ""
        echo "Commands:"
        echo "  start   - Start the bridge daemon"
        echo "  stop    - Stop the bridge daemon"
        echo "  restart - Restart the bridge daemon"
        echo "  reload  - Reload configuration without restart"
        echo "  status  - Show bridge status and recent logs"
        echo "  logs    - Follow bridge logs (Ctrl+C to stop)"
        exit 1
        ;;
esac

exit $?