#!/bin/bash

test_dir=AF_XDP
interface=""
test_mode="host"
num_queues=0
arr_pid()

# Make sure only root can run our script
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 1>&2
   #exit 1
fi

if [ $# -eq 0 ] ; then
    echo "Usage: $0 --interface <interface-name> --mode <host/peer, optional>" >&2
    exit 1
fi

while [ "$1" != "" ]; do
	case $1 in
		--interface )
			shift
			interface=$1
			;;
		--mode )
			shift
			test_mode=$1
			;;
	esac
	shift
done

#Validate interface
if [[ "$interface" == "" ]] ; then
    echo "1Usage: $0 --interface <interface-name> --mode <host/peer, optional>" >&2
    exit 1
fi


#######################FUNCTIONS###########################
function exit_on_fail()
{ 
    if [ "$1" -ne 0 ] ; then
         echo "$2"
         exit 0
    fi
}

function check_return_value()
{ 
    #echo "$1 <-----> $2"
    if [ "$1" -ne "$2"  ] ; then
         echo "$4"
         exit 0
    else
    	echo "$3"
    fi
}

function create_direc()
{
	dir_name="${test_dir}"
	mv "$dir_name"  "$dir_name-$(date +%F-%H%M)" || true
	mkdir $dir_name >&/dev/null
	#exit_on_fail "$?" "Need directory and file creation permisson"
	#echo "create_dir return : $?"
	check_return_value "$?" 0 "AF_XDP test directory Created" "Failure: Need directory and file creation permisson"
}

function check_xdpsock_binary()
{
	ls | grep xdpsock >&/dev/null
	#exit_on_fail "$?" "xdpsock binary not found"
	check_return_value "$?" 0 "" "Failure : xdpsock binary not found in the current directory"
}

function validate_interface()
{
	echo "check interface :$1"
	ifconfig $1 | grep "$1:" >&/dev/null

	#echo "Command : $?"
	check_return_value "$?" 0 "" "Failure: Interface $1 Not Found"
	echo "$interface : Setting IP Address"
	if [[ $test_mode == "host" ]] ; then
		ifconfig $interface 172.16.128.91 netmask 255.255.248.0 up promisc
		sleep 2
	elif [[ $test_mode == "peer" ]] ; then
		ifconfig $interface 172.16.128.91 netmask 255.255.248.0 up promisc
		sleep 2
	fi
	ethtool  $1 | grep "Link detected: yes" >&/dev/null
	#echo "Command : $?"
	check_return_value "$?" 0 "" "Failure: Interface $1 Link Down"
	num_queues=$(ethtool -S $interface | grep -c rx-)
}

function handle_error()
{
	rm -rf AF_XDP
}

function dummy()
{
	MODULES="be2net"
	# Find all interfaces created by driver
	declare -a interfaces
	for d in /sys/class/net/*; do
		driver="$(readlink "$d"/device/driver 2>/dev/null || readlink "$d"/driver)"
		if echo "$driver" | grep -qE "/${MODULES// /$|}$"; then
			interfaces[${#interfaces[*]}]="$(basename "$d")"
		fi
	done
	if [ ${#interfaces[*]} -eq 0 ]; then
		if [ -z "`lspci -d :`" ] && [ -z "`lspci -d :`" ]; then
			fail "no emulex NICs detected in this machine"
		else
			fail "driver failed to create any interfaces"
		fi
	fi
}

function load_driver()
{
}

function _run_xdpsock_test
{
	echo "NUM Q: $num_queues"
	if [ $num_queues -eq 0 ] ; then
		echo "Error: Number of Queues Zero"
		handle_error
		exit 0
	fi

	shared=""
	testfile=""
	mode=""
	flow=""
	while [[ $1 != "" ]] ; do 
		if [[ $1 == "zc" ]] ; then
			mode="-z"
		elif [[ $1 == "cp" ]] ; then
			mode="-c"
		elif [[ $1 == "tx" ]] ; then
			flow="-t"
		elif [[ $1 == "rx" ]] ; then
			flow="-r"
		elif [[ $1 == "shared" ]] ; then
			shared="-M"
		elif [[ $1 == "--testfile" ]] ; then
			shift
			testfile=$1
			echo "TestFile :$testfile"
		fi
		shift
	done

	for (( qid=0; qid<($num_queues - 1); qid=$qid+1 ))
	do
		echo "Running Test on QID: $qid TestFile : $testfile"
		echo "./xdpsock -i $interface -q $qid $mode $flow $shared & "
		#./xdpsock -i $interface -q $qid $mode $flow $shared & 
		./xdpsock -i $interface -q $qid $mode $flow $shared > $testfile &
		#echo $?
		if [ "$?" -ne 0 ] ; then
			echo "Failed to run xdpsock"
			return -1
		fi
		pid=$!
		sleep 10
		kill -s SIGINT $pid
		wait
		echo "cat $testfile"
		cat $testfile
		sleep 5
		break
	done
}

function run_xdpsock_test()
{
	echo "NUM Q: $num_queues"
	if [ $num_queues -eq 0 ] ; then
		echo "Error: Number of Queues Zero"
		handle_error
		exit 0
	fi

	shared=""
	testfile=""
	mode=""
	flow=""
	while [[ $1 != "" ]] ; do 
		if [[ $1 == "zc" ]] ; then
			mode="-z"
		elif [[ $1 == "cp" ]] ; then
			mode="-c"
		elif [[ $1 == "tx" ]] ; then
			flow="-t"
		elif [[ $1 == "rx" ]] ; then
			flow="-r"
		elif [[ $1 == "shared" ]] ; then
			shared="-M"
		elif [[ $1 == "--testfile" ]] ; then
			shift
			testfile=$1
			echo "TestFile :$testfile"
		fi
		shift
	done

	for (( qid=0; qid<($num_queues); qid=$qid+1 ))
	do
		res="Q00$qid";
		echo "Result File :$res"
		touch $testfile/$res
		echo "Running Test on QID: $qid TestFile : $testfile"
		echo "./xdpsock -i $interface -q $qid $mode $flow $shared & "
		#./xdpsock -i $interface -q $qid $mode $flow $shared & 
		./xdpsock -i $interface -q $qid $mode $flow $shared > $testfile/$res &
		#echo $?
		if [ "$?" -ne 0 ] ; then
			echo "Failed to run xdpsock"
			return -1
		fi
		arr_pid[$qid]=$!
	done
	echo "Test started on all Queues"
	sleep 10
	for (( qid=0; qid<($num_queues); qid=$qid+1 ))
	do
		echo "PID: ${arr_pid[$qid]}"
		kill -s SIGINT ${arr_pid[$qid]}
		kill -9 ${arr_pid[$qid]}
		wait
		res="Q00$qid";
		echo "cat $testfile"
		cat $testfile/$res
	done
}

function setup_peer_system()
{

	ssh $username@$hostname "hostname; cd ~/; bash af_xdp_test.sh --interface ens1f0 --mode peer"
	echo "SSH RETURN : $?"
	check_return_value $? 0 "SETUP_PEER_SYSTEM SUCCESS" "SETUP_PEER_SYSTEM FAILED"  
}

function test_incoming_traffic()
{
	for (( qid=0; qid<($num_queues); qid=$qid+1 ))
	do
		packets=$(ethtool -S $interface | grep rx-$qid.rx_packets)
		echo PACKETS $packets
		count1=$(echo ${packets:22:30})
		echo COUNT $count1
	done
}

function test_functionality()
{
	if [[ $test_mode == "host" ]] ; then
		declare -a test=(
		"T001"	#TEST CASE 1 : XSK ZERO COPY TX
		"T002"	#TEST CASE 2 : XSK ZERO COPY TX
		"T003"	#TEST CASE 3 : XSK ZERO COPY TX
		"T004"	#TEST CASE 4 : XSK ZERO COPY TX
		)
		for opt in "${test[@]}"
		do
			echo "Testing $opt"
			outfile=$test_dir/$opt
			mkdir $outfile
			case $opt in
				"T001" )
					echo "Running TEST CASE $opt:"
					touch $outfile 
					run_xdpsock_test zc tx --testfile $outfile 
					;;
				"T002" )
					touch $outfile 
					echo "Running TEST CASE $opt:"
					run_xdpsock_test zc rx --testfile $outfile 
					;;
				"T003" )
					touch $outfile 
					echo "Running TEST CASE $opt:"
					run_xdpsock_test cp tx --testfile $outfile
					;;
				"T004" )
					touch $outfile 
					echo "Running TEST CASE $opt:"
					run_xdpsock_test cp rx --testfile $outfile
					;;
				"T005" )
					touch $outfile 
					echo "Running TEST CASE $opt:"
					_run_xdpsock_test zc tx shared --testfile $outfile
					;;
				"T006" )
					touch $outfile 
					echo "Running TEST CASE $opt:"
					_run_xdpsock_test zc rx shared --testfile $outfile
					;;
				"T003" )
					echo "Running TEST CASE $opt:"
					;;
				"T003" )
					echo "Running TEST CASE $opt:"
					;;
				"T003" )
					echo "Running TEST CASE $opt:"
					;;
			esac
		done
	elif [[ $test_mode == "peer" ]] ; then
		echo "Setting UP peer"
	fi
}

function start_traffic_in_peer()
{
	load_driver
	validate_interface $interface
	check_xdpsock_binary
	./xdpsock -i $interface -t -q 0 -z &
	echo "XDPSOCK RETURN :$?"
}

function run_test()
{
	if [[ $test_mode == "peer" ]] ; then
		start_traffic_in_peer
	elif [[ $test_mode == "host" ]] ; then
		load_driver
		validate_interface $interface
		check_xdpsock_binary
		create_direc
		#setup_peer_system $peer $username $password $path
		test_incoming_traffic $interface
		test_functionality $interface
	fi
}

#######################BODY###########################
run_test
