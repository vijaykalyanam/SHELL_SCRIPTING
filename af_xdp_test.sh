#!/bin/bash

test_dir=AF_XDP
interface=""
test_mode="host"

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
		ifconfig $interface 12.1.128.9 netmask 255.255.248.0 up promisc
	elif [[ $test_mode == "peer" ]] ; then
		ifconfig $interface 12.1.128.9 netmask 255.255.248.0 up promisc
	fi
	ethtool  $1 | grep "Link detected: yes" >&/dev/null
	#echo "Command : $?"
	check_return_value "$?" 0 "" "Failure: Interface $1 Link Down"
}

function handle_error()
{
	rm -rf AF_XDP
}

function dummy()
{
	MODULES="benet"
	# Find all interfaces created by driver
	declare -a interfaces
	for d in /sys/class/net/*; do
		driver="$(readlink "$d"/device/driver 2>/dev/null || readlink "$d"/driver)"
		if echo "$driver" | grep -qE "/${MODULES// /$|}$"; then
			interfaces[${#interfaces[*]}]="$(basename "$d")"
		fi
	done
	if [ ${#interfaces[*]} -eq 0 ]; then
		if [ -z "`lspci -d 1924:`" ] && [ -z "`lspci -d 10ee:0100`" ]; then
			fail "no Solarflare NICs detected in this machine"
		else
			fail "driver failed to create any interfaces"
		fi
	fi
}

function load_driver()
{
	./load.sh
}
testfile="TestOutput"
function _run_xdpsock_test
{
	num_queues=$(ethtool -S $interface | grep -c rx-)
	echo "NUM Q: $num_queues"
	if [ $num_queues -eq 0 ] ; then
		echo "Error: Number of Queues Zero"
		handle_error
		exit 0
	fi

	while [ $1 != "" ] ; do 
		if [[ $1 == "zc" ]] ; then
			mode="-z"
		elif [[ $1 == "cp" ]] ; then
			mode="-c"
		else
			echo "Error: Mode required"
			exit 1
		fi

		if [[ $2 == "tx" ]] ; then
			flow="-t"
		elif [[ $2 == "rx" ]] ; then
			flow="-r"
		else
			echo "Error:  Flow required"
			exit 1
		fi

		if [[ $3 == "shared" ]] ; then
			shared="-M"
		else
			shared=""
		fi

		testfile=$4
		if [[ $testfile == "" ]] ; then
			echo "Test File is required."
			exit 1
		fi
	done

	for (( qid=0; qid<($num_queues - 1); qid=$qid+1 ))
	do
		echo "Running Test on QID: $qid"
		#./xdpsock -i $interface -q $qid $mode $flow $shared & 
		./xdpsock -i $interface -q $qid $mode $flow $shared > ./$testfile & 
		#echo $?
		if [ "$?" -ne 0 ] ; then
			echo "Failed to run xdpsock"
			return -1
		fi
		pid=$!
		sleep 20 
		kill -9 $pid
		wait 2>/dev/null
		cat $testfile
	done
}

function run_xdpsock_test()
{
	num_queues=$(ethtool -S $interface | grep -c rx-)
	echo "NUM Q: $num_queues"
	if [ $num_queues -eq 0 ] ; then
		echo "Error: Number of Queues Zero"
		handle_error
		exit 0
	fi
	for (( i=0; i<($num_queues - 1); i=$i+1 ))
	do
		if [ $2 -eq 0 ] ; then
			echo "Running ZC Mode Transmits on QID $i"
			./xdpsock -i $interface -q $i -t -z & 
		elif [ $2 -eq 1 ] ; then
			echo "Running SHARED ZC Mode Transmits on QID $i"
			./xdpsock -i $interface -q $i -t -z -M & 
		elif [ $2 -eq 2 ] ; then
			echo "Running SKB Mode Transmits on QID $i"
			./xdpsock -i $interface -q $i -t -c & 
		elif [ $2 -eq 3 ] ; then
			echo "Running SHARED SKB Mode Transmits on QID $i"
			./xdpsock -i $interface -q $i -t -c -M & 
		fi

		#echo "Testing  $mode transmits - Qid :$i"
		echo $?
		if [ "$?" -ne 0 ] ; then
			echo "Failed to run xdpsock"
			return -1
		fi
		pid=$!
		sleep 2 
		#kill -9 $pid &>/dev/null 
		kill -9 $pid >/dev/null 2>&/dev/null
		wait
	done
}

function _run_test()
{
	run_xdpsock_test zc tx
}

function setup_peer_system()
{

	ssh $username@$hostname "hostname; cd ~/; bash af_xdp_test.sh --interface ens1f0 --mode peer"
	echo "SSH RETURN : $?"
	check_return_value $? 0 "SETUP_PEER_SYSTEM SUCCESS" "SETUP_PEER_SYSTEM FAILED"  
}

function test_functionality()
{
	if [[ $test_mode == "host" ]] ; then
		declare -a test=(
		"T001"	#TEST CASE 1 : XSK ZERO COPY TX
		"T002"	#TEST CASE 1 : XSK ZERO COPY TX
		"T003"	#TEST CASE 1 : XSK ZERO COPY TX
		"T004"	#TEST CASE 1 : XSK ZERO COPY TX
		)
		for opt in "${test[@]}"
		do
			echo "Testing $opt"
			case $opt in
				"T001" )
					echo "Running TEST CASE $opt:"
					_run_xdpsock_test zc tx
					;;
				"T002" )
					echo "Running TEST CASE $opt:"
					_run_xdpsock_test zc rx 
					;;
				"T003" )
					echo "Running TEST CASE $opt:"
					_run_xdpsock_test cp tx
					;;
				"T004" )
					echo "Running TEST CASE $opt:"
					_run_xdpsock_test cp rx
					;;
				"T005" )
					echo "Running TEST CASE $opt:"
					_run_xdpsock_test zc tx shared
					;;
				"T006" )
					echo "Running TEST CASE $opt:"
					_run_xdpsock_test zc rx shared
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
		test_functionality $interface
	fi
}

#######################BODY###########################
run_test
