#！/bin/bash

#Date: 2024/10/16 
#Author: Alex
#Mail: 
#Function: Used to collect CPU usage report on a ubuntu system 
#Version: V 1.0

FILE=/tmp/cpu_report_$(date +%F).txt

# Evaluate if the commands are available
which lscpu 1> /dev/null || { echo "please install lscpu command first"; exit 1; }
which top 1> /dev/null || { echo "please install top command first"; exit 1; }
which mpstat 1> /dev/null || { echo "please install mpstat command first"; exit 1; }
which vmstat 1> /dev/null || { echo "please install vmstat command first"; exit 1; }
which seq 1> /dev/null || { echo "please install seq command first"; exit 1; }

echo "***CPU performance report collection will take approximately 1 minute to complete.  Now is $(date). please wait...***"

echo "***Start to collect the CPU performance data. Now is $(date)***" >> $FILE
echo -e '\n' >> $FILE

#Collect CPU Info
echo "***Collect CPU Info. Now is $(date)***" >> $FILE
lscpu  >> $FILE || { echo "lscpu command execute failed"; exit 1; }
echo -e '\n\n\n' >> $FILE

#Collect CPU overall report with top
echo "***Collect CPU overall report with top. Now is $(date)***" >> $FILE
top -c  -n 6 -b >> $FILE || { echo "top command execute failed"; exit 1; }
echo -e '\n\n\n' >> $FILE

#Collect CPU overall report with mpstat
echo "***Collect CPU overall report with mpstat. Now is $(date)***" >> $FILE
mpstat -P ALL 1 6 >> $FILE || { echo "mpstat command execute failed"; exit 1; }
echo -e '\n\n\n' >> $FILE

# Collect CPU context switch report
echo "***Collect CPU context switch report. Now is $(date)***" >> $FILE
vmstat 1 6 >> $FILE || { echo "vmstat command execute failed"; exit 1; }
echo -e '\n\n\n' >> $FILE

# Collect Hardware interrupt data
echo "***Collect Hardware interrupt data. Now is $(date)***" >> $FILE
for i in $(seq 1 6); do cat /proc/interrupts >> $FILE; echo >> $FILE; sleep 1; done
echo -e '\n\n\n' >> $FILE

# Collect software interrupt data
echo "***Collect software interrupt data. Now is $(date)***" >> $FILE
for i in $(seq 1 6); do cat /proc/softirqs >> $FILE; echo >> $FILE; sleep 1; done
echo -e '\n\n\n' >> $FILE

# List top 10 thread used the most CPU resources
echo "***List top 10 thread used the most CPU resources. Now is $(date)***" >> $FILE
for i in $(seq 1 6); do ps H -eo user,pid,ppid,tid,time,%cpu,%mem,cmd --sort=-pcpu|head -n 10 >> $FILE; echo >> $FILE; sleep 1; done
echo -e '\n\n\n' >> $FILE
echo "Successfully collected. Now is $(date)" >> $FILE

echo "***The report has been successfully collected and stored in the file ${FILE}. Now is $(date).***"

exit 0
