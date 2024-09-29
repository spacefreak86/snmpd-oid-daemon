# snmpd-oid-daemon

A customizable daemon written in Bash to provide custom OIDs to snmpd.

# Requirements
snmpd-oid-daemon runs with Bash version 4.3 or later.

# Installation
* Copy **snmpd-oid-daemon.sh** to your system where it is accessible by snmpd (e.g. to /usr/local/bin).
* Edit **snmpd.conf** and add the following line, replace OID with your custom base OID (e.g. .1.3.6.1.4.1.8072.9999.9999).
```
pass_persist OID /PATH/TO/snmpd-oid-agent.sh --base-oid OID
```
* Restart snmpd.

# Data gathering functions
* Take a look at the existing functions to learn which ones already exist and how they are implemented.
* Implement your own function or overwrite an existing one in the overload-script if neccessary.
* Overwrite the global array DATA_FUNCS in the overload-script to enable/disable functions or change their refresh delay.

# Known issues
* The interface to snmpd does not support type Gauge64. One way arround this is to use String instead and convert to int64 on the receiving end.
* The function 'gather_filesum_data' in its current form requires snmpd to run as root which is not always the case. Overload the function (--overload-script) if this is an issue in your case.
