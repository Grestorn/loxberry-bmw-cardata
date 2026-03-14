#!/bin/bash
#
# BMW CarData Bridge Control Script
# Controls the bmw-cardata-bridge daemon (per-account)
#

SCRIPT_DIR="REPLACELBPBINDIR"
DATA_DIR="REPLACELBPDATADIR"
LOG_DIR="REPLACELBPLOGDIR"
DAEMON="$SCRIPT_DIR/bmw-cardata-bridge.pl"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Parse --account parameter
ACCOUNT_ID=""
COMMAND=""
for arg in "$@"; do
    case "$arg" in
        --account=*)
            ACCOUNT_ID="${arg#*=}"
            ;;
        --account)
            # Next argument will be the account ID
            NEXT_IS_ACCOUNT=1
            ;;
        *)
            if [ "$NEXT_IS_ACCOUNT" = "1" ]; then
                ACCOUNT_ID="$arg"
                NEXT_IS_ACCOUNT=""
            else
                COMMAND="$arg"
            fi
            ;;
    esac
done

# For start-all / stop-all, no account needed
case "$COMMAND" in
    start-all|stop-all)
        # These commands iterate over all accounts
        ;;
    *)
        if [ -z "$ACCOUNT_ID" ] && [ "$COMMAND" != "" ]; then
            echo "Usage: $0 --account <account_id> {start|stop|restart|reload|status|logs}"
            echo "       $0 {start-all|stop-all}"
            exit 1
        fi
        ;;
esac

# Account-specific paths
ACCOUNT_DIR="$DATA_DIR/accounts/$ACCOUNT_ID"
PID_FILE="$ACCOUNT_DIR/bridge.pid"
LOG_FILE="$LOG_DIR/bridge-${ACCOUNT_ID}.log"

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
        echo "Bridge [$ACCOUNT_ID] is already running (PID $(get_pid))"
        return 1
    fi

    echo "Starting BMW CarData Bridge [$ACCOUNT_ID]..."
    perl "$DAEMON" --account "$ACCOUNT_ID" --daemon

    # Wait a moment and check if started
    sleep 2
    if is_running; then
        echo "Bridge [$ACCOUNT_ID] started successfully (PID $(get_pid))"
        return 0
    else
        echo "Failed to start bridge [$ACCOUNT_ID]. Check log: $LOG_FILE"
        return 1
    fi
}

stop() {
    if ! is_running; then
        echo "Bridge [$ACCOUNT_ID] is not running"
        return 0
    fi

    local pid=$(get_pid)
    echo "Stopping BMW CarData Bridge [$ACCOUNT_ID] (PID $pid)..."

    kill -TERM "$pid"

    # Wait for graceful shutdown
    local count=0
    while is_running && [ $count -lt 10 ]; do
        sleep 1
        count=$((count + 1))
    done

    if is_running; then
        echo "Bridge [$ACCOUNT_ID] did not stop gracefully, forcing..."
        kill -KILL "$pid"
        sleep 1
    fi

    rm -f "$PID_FILE"
    echo "Bridge [$ACCOUNT_ID] stopped"
    return 0
}

restart() {
    echo "Restarting BMW CarData Bridge [$ACCOUNT_ID]..."
    stop
    sleep 2
    start
}

reload() {
    if ! is_running; then
        echo "Bridge [$ACCOUNT_ID] is not running, cannot reload"
        return 1
    fi

    local pid=$(get_pid)
    echo "Reloading configuration [$ACCOUNT_ID] (PID $pid)..."
    kill -HUP "$pid"
    echo "Configuration reload signal sent"
    return 0
}

status() {
    if is_running; then
        local pid=$(get_pid)
        echo "BMW CarData Bridge [$ACCOUNT_ID] is running (PID $pid)"

        # Show last log lines
        if [ -f "$LOG_FILE" ]; then
            echo ""
            echo "Last 10 log entries:"
            tail -10 "$LOG_FILE"
        fi
        return 0
    else
        echo "BMW CarData Bridge [$ACCOUNT_ID] is not running"
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

start_all() {
    echo "Starting all BMW CarData bridges..."
    local started=0
    for ACCT_DIR in "$DATA_DIR"/accounts/*/; do
        if [ -d "$ACCT_DIR" ] && [ -f "$ACCT_DIR/tokens.json" ] && [ -f "$ACCT_DIR/config.json" ]; then
            local acct=$(basename "$ACCT_DIR")
            ACCOUNT_ID="$acct"
            ACCOUNT_DIR="$ACCT_DIR"
            PID_FILE="$ACCOUNT_DIR/bridge.pid"
            LOG_FILE="$LOG_DIR/bridge-${acct}.log"
            start
            started=$((started + 1))
        fi
    done
    echo "Started $started bridge(s)"
}

stop_all() {
    echo "Stopping all BMW CarData bridges..."
    local stopped=0
    for ACCT_DIR in "$DATA_DIR"/accounts/*/; do
        if [ -d "$ACCT_DIR" ]; then
            local acct=$(basename "$ACCT_DIR")
            ACCOUNT_ID="$acct"
            ACCOUNT_DIR="$ACCT_DIR"
            PID_FILE="$ACCOUNT_DIR/bridge.pid"
            LOG_FILE="$LOG_DIR/bridge-${acct}.log"
            if is_running; then
                stop
                stopped=$((stopped + 1))
            fi
        fi
    done
    echo "Stopped $stopped bridge(s)"
}

# Main
case "$COMMAND" in
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
    start-all)
        start_all
        ;;
    stop-all)
        stop_all
        ;;
    *)
        echo "Usage: $0 --account <account_id> {start|stop|restart|reload|status|logs}"
        echo "       $0 {start-all|stop-all}"
        echo ""
        echo "Per-account commands:"
        echo "  start   - Start the bridge daemon for an account"
        echo "  stop    - Stop the bridge daemon for an account"
        echo "  restart - Restart the bridge daemon for an account"
        echo "  reload  - Reload configuration without restart"
        echo "  status  - Show bridge status and recent logs"
        echo "  logs    - Follow bridge logs (Ctrl+C to stop)"
        echo ""
        echo "Global commands:"
        echo "  start-all - Start bridges for all configured accounts"
        echo "  stop-all  - Stop all running bridges"
        exit 1
        ;;
esac

exit $?
