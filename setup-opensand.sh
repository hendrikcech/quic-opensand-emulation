#!/bin/bash

# _osnd_configure_opensand_orbit(orbit)
# Configures a constant delay based on the given orbit.
function _osnd_configure_opensand_orbit() {
	local orbit="$1"

	local delay_ms=-1
	case "$orbit" in
	"GEO")
		delay_ms=125
		;;
	"MEO")
		delay_ms=55
		;;
	"LEO")
		delay_ms=18
		;;
	esac

	if [ $delay_ms -lt 0 ]; then
		return
	fi

	for entity in sat gw st; do
		xmlstarlet edit -L \
		 	--update "/configuration/common/global_constant_delay" --value "true" \
		 	--update "/configuration/common/delay" --value "$delay_ms" \
		 	"${OSND_TMP}/config_${entity}/core_global.conf"
	done
}

# _osnd_configure_opensand_attenuation(attenuation)
# Configures the given constant signal attenuation
function _osnd_configure_opensand_attenuation() {
	local attenuation="$1"

	if [ "$attenuation" -lt 0 ]; then
		return
	fi

	for entity in st gw; do
		# Use "Ideal" model for up- and downlink with 20db clear_sky attenuation
		xmlstarlet edit -L \
			--update "/configuration/uplink_physical_layer/attenuation_model_type" --value "Ideal" \
			--update "/configuration/uplink_physical_layer/clear_sky_condition" --value "20" \
			--update "/configuration/downlink_physical_layer/attenuation_model_type" --value "Ideal" \
			--update "/configuration/downlink_physical_layer/clear_sky_condition" --value "20" \
			"${OSND_TMP}/config_${entity}/core.conf"

		# Configure attenuation
		xmlstarlet edit -L \
			--update "/configuration/ideal/ideal_attenuations/ideal_attenuation/@attenuation_value" --value "$attenuation" \
			"${OSND_TMP}/config_${entity}/plugins/ideal.conf"
	done
}

# _osnd_configure_opensand_min_condition()
function _osnd_configure_opensand_min_condition() {
	# Use "Constant" model for downlink on st and gw
	for entity in st gw; do
		xmlstarlet edit -L \
			--update "/configuration/downlink_physical_layer/minimal_condition_type" --value "Constant" \
			"${OSND_TMP}/config_${entity}/core.conf"
	done

	# Constant minimal condition type also on sat
	xmlstarlet edit -L \
		--update "/configuration/sat_physical_layer/minimal_condition_type" --value "Constant" \
		"${OSND_TMP}/config_sat/core.conf"

	# Configure minimal downlink threshold on all entities
	for entity in sat gw st; do
		xmlstarlet edit -L \
			--update "/configuration/constant/threshold" --value "0" \
			"${OSND_TMP}/config_${entity}/plugins/constant.conf"
	done
}

# _osnd_configure_opensand_carriers()
function _osnd_configure_opensand_carriers() {
	for entity in sat gw st; do
		# Set forward down band to CCM
		# Remove premium return band
		# Use full bandwidth remaining return band
		xmlstarlet edit -L \
			--update "//forward_down_band/spot[@id='1']/carriers_distribution/down_carriers/@access_type" --value "CCM" \
			--delete "//return_up_band/spot[@id='1']/carriers_distribution/up_carriers[@category='Premium']" \
			--update "//return_up_band/spot[@id='1']/bandwidth" --value "19.98" \
			--update "//return_up_band/spot[@id='1']/carriers_distribution/up_carriers[@category='Standard']/@ratio" --value "100" \
			--update "//return_up_band/spot[@id='1']/carriers_distribution/up_carriers[@category='Standard']/@symbol_rate" --value "14.8E6" \
			"${OSND_TMP}/config_${entity}/core_global.conf"
	done
}

# osnd_setup_opensand(orbit, attenuation)
function osnd_setup_opensand() {
	local orbit="$1"
	local attenuation="${2:--1}"

	# Copy configurations
	for entity in sat gw st; do
		if [ -e "${OSND_TMP}/config_${entity}" ]; then
			rm -rf "${OSND_TMP}/config_${entity}"
		fi
		cp -r "${OPENSAND_CONFIGS}/${entity}" "${OSND_TMP}/config_${entity}"
	done

	# Modify configuration based on parameter
	_osnd_configure_opensand_orbit "$orbit"
	_osnd_configure_opensand_attenuation "$attenuation"
	_osnd_configure_opensand_min_condition
	_osnd_configure_opensand_carriers

	# Start satelite
	log D "Launching satellite into (name-)space"
	sudo ip netns exec osnd-sat killall opensand-sat -q
	tmux -L ${TMUX_SOCKET} new-session -s opensand-sat -d "sudo ip netns exec osnd-sat bash"
	sleep $TMUX_INIT_WAIT
	tmux -L ${TMUX_SOCKET} send-keys -t opensand-sat "mount -o bind ${OSND_TMP}/config_sat /etc/opensand" Enter
	tmux -L ${TMUX_SOCKET} send-keys -t opensand-sat "opensand-sat -a ${EMU_SAT_IP%%/*} -c /etc/opensand" Enter

	# Start gateway
	log D "Aligning the gateway's satellite dish"
	sudo ip netns exec osnd-gw killall opensand-gw -q
	tmux -L ${TMUX_SOCKET} new-session -s opensand-gw -d "sudo ip netns exec osnd-gw bash"
	sleep $TMUX_INIT_WAIT
	tmux -L ${TMUX_SOCKET} send-keys -t opensand-gw "mount -o bind ${OSND_TMP}/config_gw /etc/opensand" Enter
	tmux -L ${TMUX_SOCKET} send-keys -t opensand-gw "opensand-gw -i 0 -a ${EMU_GW_IP%%/*} -t tap-gw -c /etc/opensand" Enter

	# Start statellite terminal
	log D "Connecting the satellite terminal"
	sudo ip netns exec osnd-st killall opensand-st -q
	tmux -L ${TMUX_SOCKET} new-session -s opensand-st -d "sudo ip netns exec osnd-st bash"
	sleep $TMUX_INIT_WAIT
	tmux -L ${TMUX_SOCKET} send-keys -t opensand-st "mount -o bind ${OSND_TMP}/config_st /etc/opensand" Enter
	tmux -L ${TMUX_SOCKET} send-keys -t opensand-st "opensand-st -i 1 -a ${EMU_ST_IP%%/*} -t tap-st -c /etc/opensand" Enter
}

# If script is executed directly
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	declare -F log >/dev/null || function log() {
		local level="$1"
		local msg="$2"

		echo "[$level] $msg"
	}

	osnd_setup_opensand "$@"
fi
