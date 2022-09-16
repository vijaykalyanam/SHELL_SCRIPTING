#!/bin/bash

#PARSE CMDLINE ARGUMENTS
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

