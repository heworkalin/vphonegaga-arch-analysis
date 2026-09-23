#!/bin/bash
#电脑端adb shell，持续输出全部进程的 PID PPID CMDLine
while true; do
	adb -s 127.0.0.1:5555 shell ps -ef | grep titan >> process_log.txt
	sleep 0.3
done

