require()
{
	local _x
#	echo ${1}
	eval "_x=\$${1}"
	if [ -z ${_x} ]; then
		echo "${1} not defined!"
		exit 1
#	else
#		echo "\$${1}: ${_x}"
	fi
}
