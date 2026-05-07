
=== Page 1 ===
 SAS HDD Firmware Update Instructions  07-Nov-2018 
 1 
 
 
SAS Firmware Update Instructions 
 
Enterprise Performance 10K.8 SAS 
HDD firmware update version N005 
 
This firmware update is for the Seagate 
Enterprise Performance 10K.8 HDD SAS 
family only.   
 
Backup all data contained on the drive 
prior to running the update. 
 
See the End User License Agreement 
below for specific information about these 
software tools. 
 
 
 
 
This firmware release only supports the following models: 
 
Enterprise Performance 10K.8 SAS HDD (Thunderbolt) 
 
Format Security Model Part Number New 
FW Firmware File 
5xxN 
STD ST300MM0008 1V8200 N005 
ThunderboltEntPerfSAS-STD-5xxN-
N005.LOD 
STD ST600MM0088 1FD200 N005 
STD ST900MM0168 1FE200 N005 
STD ST1200MM0088 1FF200 N005 
 
 
Note: The firmware above does NOT support SATA, SED, 4kN, 5xxE or any other 
default sector size other than 5xxN.  It is only for the four models in the list above.  
 
STD    Standard 
SED    Self Encrypting Drive 
4kN    4k Native sector size 
5xxE   Advanced Format (512 byte emulation from 4k physical) 
5xxN   Usually 512N Native sector size 


=== Page 2 ===
 SAS HDD Firmware Update Instructions  07-Nov-2018 
 2 
If your current Enterprise Performance 10K.8 SAS HDD firmware does not begin with 
the digits “N002” or “N003” or “N004” then you have a configuration which is not 
compatible with N005.  Otherwise, you might have a unique OEM version in which case 
please contact your OEM for firmware updates for these drives. 
 
Warning, possible loss of data if this firmware is downloaded to unsupported models! 
 
DO NOT run this firmware update on RAID systems. 
DO NOT turn the power off during the firmware update procedure. 
 
BEFORE YOU BEGIN: 
1. Make sure you have backed up all of your important files and critical data. 
2. Save any work in progress. 
3. Close all other open applications. 
4. Disconnect all external storage devices. 
 
 
Always handle the drive carefully so you do not cause internal damage to the heads and 
media inside the drives.   Drives are sensitive devices. 
 
A warning about RAID 
RAID systems are extremely sensitive to disruptions to individual drives.  It is not 
uncommon for low level disk drive diagnostics to cause RAID management software to 
fault a drive that is slowed down by testing or firmware download.  For this reason, we 
highly recommend that you use disk management tools provided by your RAID 
controller manufacturer if they are available. If these tools are not available, you might 
consider taking the RAID offline to a maintenance mode or rebooting the system to 
temporary bootable media and running diagnostics from there.  Seagate recommends 
that you use disk utility tools provided by your RAID controller manufacturer. 
Among others, RAID management software is available from 3Ware, Adaptec and LSI. 
Here are the instructions for updating SAS firmware: 
 
The method you choose to update the firmware on the drive will depend on your 
operating system, system utilities or work bench environment. 
 
Windows Tool 
 
Windows operating systems tolerate firmware downloads to SAS disk drives in JBOD 
mode.  Drives in RAID configurations should not be given new firmware unless a special 
tool is provided by the RAID controller manufacturer. 
 
Seagate’s SeaTools for Windows may be used to download firmware to SAS disk drives 
in JBOD mode.  You will find SeaTools for Windows at 

=== Page 3 ===
 SAS HDD Firmware Update Instructions  07-Nov-2018 
 3 
www.seagate.com/support/seatools  and select the Downloads tab.  After SeaTools is 
installed on the system, you will find Download Firmware (SCSI/SAS/FC) on the 
Advanced Tests menu. 
 
 
The firmware files will be either .LOD or .SEA file 
types.   
 
Important: These files must be copied to the 
SeaTools for Windows folder. 
 
 
 
Command Line Interface Tools 
 
Two command line interface tools are available for firmware download.  Seaflashlin is 
for Linux only, and is the precursor to SeaChest_Firmware.  SeaChest_Firmware is 
available for both Linux and Windows and they share the same command line structure.   
Therefore, there are two command line choices for Linux and one for Windows.  All of 
these tools have extensive documentation available.  
 
Note: Windows operating systems do NOT allow firmware download to SATA drives 
unless the drives support the Deferred Download mode. 
 
SeaChest_Firmware is our most current tool.  The Linux version is shown below.  The 
Windows version does not reference devices as “/dev/sg” but rather as PDx.  Please 
see the SeaChest_Firmware for Windows documentation for specific examples. 
 
 
=============================================================================== 
 SeaChest_Firmware for Linux - Seagate drive utilities 
 Copyright (c) 2018 Seagate Technology LLC and/or its Affiliates, All Rights Reserved 
 SeaChest_Firmware Version: 2.5.4 
 Build Date: Oct 18 2018 
=============================================================================== 
Usage 
===== 
        SeaChest_Firmware [-d <sg_device>] {arguments} {options} 
 
Examples 
======== 
        SeaChest_Firmware --scan 
        SeaChest_Firmware -d /dev/sg2 -i 
        SeaChest_Firmware -d /dev/sg2 --fwdlInfo 
        SeaChest_Firmware -d /dev/sg2 --downloadFW fwfilename 
        SeaChest_Firmware -d /dev/sg2 --fwdlConfig configfile.cfs 
 
Utility Arguments  (partial listing) 
================= 
        -s, --scan 
        -F, --scanFlags [option list] 
        -d, --device <device handle> 
        -i, --deviceInfo 


=== Page 4 ===
 SAS HDD Firmware Update Instructions  07-Nov-2018 
 4 
        --SATInfo 
        --testUnitReady 
        --fwdlInfo 
        --downloadFW [fwfilename] 
        --downloadMode [full | segmented | deferred] 
        --activateFW 
        --fwdlConfig [config file] 
        --fwdlDryRun 
        --fwdlSegSize [segment size in 512B blocks] 
 
Utility Options  (partial listing) 
=============== 
        -h, --help 
        -V, --version 
        --license 
 
First, run the --scan  option to determine what /dev/sg# assignment lines up to your 
disk drive.  This option also will show you other details about the drive including the 
current firmware revision.  Like this: 
Vendor     Handle       Model Number       Serial Number     FwRev 
ATA        /dev/sg0     ST94813AS          3AA043KP          3.03 
SEAGATE    /dev/sg1     ST1000NM0011       ZAA15VAS          SN03 
 
The typical ordinary command line looks something like this: 
SeaChest_Firmware -d /dev/sg2 --downloadFW fwfilename 
--modelMatch is a model number verification based on the device Inquiry response.  --
modelMatch scans all sg devices on the system. 
The tool has two batch modes, which can be used thusly: 
SeaChest_Firmware –d all --modelMatch <model_number> --downloadFW fwfilename 
 
Note: Use of –d all --modelMatch mode is preferred for batch processing of sg (SCSI 
generic) SAS disk drives.  The --modelMatch mode may also be used on Enterprise 
SATA disk drives.  Desktop and notebook SATA drives firmware is usually combined 
with a Seagate-prepared CFS firmware configuration file.   
 
The <cfs_file> noted above is a Seagate-prepared compatible firmware selector file 
which is used to match up the right firmware for a particular SATA drive. 
SeaChest_Firmware -d /dev/sg2 --fwdlConfig configfile.cfs 
 
Note: Batch processing of SATA drives should use a Seagate prepared CFS file. 
 
Both of these modes assume that the relevant firmware files are located in the current 
working directory. 
See the SeaChest_Firmware.-Lin.txt file for a complete description of the software. 

=== Page 5 ===
 SAS HDD Firmware Update Instructions  07-Nov-2018 
 5 
Raw Firmware Data Files 
You will need the Seagate firmware file to run the simple command line Linux tool. This 
file will have the .LOD filename extension and should be located in the current working 
directory. This firmware file should never be used outside of the specific product family 
models and part numbers listed with the firmware release. Incorrect usage of the .LOD 
may result in data loss or even product failure. Seagate Technology is not responsible 
for lost user data. See the End User License Agreement below for specific information 
about these software tools. 
Using Traditional Linux Firmware Tools 
For SAS drive firmware downloads you might use the Linux "sg_write_buffer" 
command.   The sg command stands for the (SCSI Generic driver) and is an off-the-
shelf Linux command that is kept updated by the Linux community.  It may be able to 
work with various RAID cards and see the individual drives.   You will need to load the 
“sg3_utils” package if not already in your Linux kernel. 
For Ubunto  _  apt-get sg3_utils 
For Fedora/redhat/centros   yum install sq3_untils 
============================================================ 
SAS Drive FW Download - use sg_write_buffer     
example loads "ST9600205SS_0002.lod"  firmware 
============================================================ 
1.  Be in the directory where the .lod files is located then run the sg_write_buffer cmd.  
More details below. 
2.  On larger code files you must specify --length=file size.  Use ls -l command to get the 
file size of the code (to use in the sg_write_buffer command string 
 
# ls -l ST9600205SS_0002_servo-x106.lod 
-rw-r--r-- 1 root root 1238016 2011-08-17 10:46  ST9600205SS_0002.lod 
 
3.  Identify the /dev/sgx device.  Run the lsscsi -g command to see target devices 
/dev/sg#  
4.  Run sg_write_buffer command to the target device.  Here is an example of a 
firmware download to a Seagate Constellation ES.1 model ST9600205SS: 
 
 # sg_write_buffer -v --in=/var/tmp/ST9600205SS_0002.lod --length=1238016 --mode=5 
/dev/sg3 
   Write buffer cmd: 3b 05 00 00 00 00 12 e4 00 00 
 
or  sg_write_buffer -v --in=<fw file name> -l=<file size> -m=5 
5.  Then use Linux SMARTCTL to verify what code is on the disk 

=== Page 6 ===
 SAS HDD Firmware Update Instructions  07-Nov-2018 
 6 
# smartctl -i /dev/sdc 
http://smartmontools.sourceforge.net 
Device: SEAGATE  ST9600205SS      Version: 0002 
Serial number: 6XR1xxxx 
 
Support 
Seagate offers technical support for disk drive installation. If you have any questions 
related to Seagate products and technologies, feel free to submit your request on our 
web site. See the web site for a list of world-wide telephone numbers. 
Seagate Support: http://www.seagate.com/support-home/ 
Contact Us:  http://www.seagate.com/contacts/ 
 
This software uses open source packages obtained with permission from the relevant 
parties. For a complete list of open source components, sources and licenses, please 
see our Linux USB Boot Maker Utility FAQ for additional information. 
Linux USB Boot Maker FAQ: 
http://support.seagate.com/firmware/usbbootmaker_faq.html 
Copyright © 2018 Seagate Technology LLC and/or its Affiliates,. All rights reserved. 
  

=== Page 7 ===
 SAS HDD Firmware Update Instructions  07-Nov-2018 
 7 
END USER LICENSE AGREEMENT  
FOR SEAGATE SOFTWARE 
 
PLEASE READ THIS END USER LICENSE AGREEMENT (“EULA”) CAREFULLY.  BY CLICKING “I AGREE” OR 
TAKING ANY STEP TO DOWNLOAD, SET-UP, INSTALL OR USE ALL OR ANY PORTION OF THIS PRODUCT 
(INCLUDING, BUT NOT LIMITED TO, THE SOFTWARE AND ASSOCIATED FILES (THE “SOFTWARE”), 
HARDWARE (“HARDWARE”), DISK (S), OR OTHER MEDIA) (COLLECTIVELY, THE “PRODUCT”) YOU AND 
YOUR COMPANY ACCEPT ALL THE TERMS AND CONDITIONS OF THIS EULA.  IF YOU ACQUIRE THIS 
PRODUCT FOR YOUR COMPANY’S USE, YOU REPRESENT THAT YOU ARE AN AUTHORIZED 
REPRESENTATIVE WHO HAS THE AUTHORITY TO LEGALLY BIND YOUR COMPANY TO THIS EULA.  IF YOU 
DO NOT AGREE, DO NOT CLICK “I AGREE” AND DO NOT DOWNLOAD, SET-UP, INSTALL OR USE THE 
SOFTWARE.   
 
1.  Ownership.  This EULA applies to the Software and Products of Seagate Technology LLC and the 
affiliates controlled by, under common control with, or controlling Seagate Technology LLC, including 
but not limited to affiliates operating under the LaCie name or brand, (collectively, “Seagate”, “we”, 
“us”, “our”).  Seagate and its suppliers own all right, title, and interest in and to the Software, including 
all intellectual property rights therein.  The Software is licensed, not sold.  The structure, organization, 
and code of the Software are the valuable trade secrets and confidential information of Seagate and its 
suppliers.  The Software is protected by copyright and other intellectual property laws and treaties, 
including, without limitation, the copyright laws of the United States and other countries. The term 
“Software" does not refer to or include “Third-Party Software”.  “Third-Party Software” means certain 
software licensed by Seagate from third parties that may be provided with the specific version of 
Software that you have licensed.  The Third-Party Software is generally not governed by the terms set 
forth below but is subject to different terms and conditions imposed by the licensors of such Third-Party 
Software.  The terms of your use of the Third-Party Software are subject to and governed by the 
respective license terms, except that this Section 1 and Sections 5 and 6 of this Agreement also govern 
your use of the Third-Party Software.  You may identify and view the relevant licenses and/or notices for 
such Third-Party Software for the Software you have received pursuant to this EULA at 
http://www.seagate.com/support/by-topic/downloads/ , or at http://www.lacie.com/support/ for LaCie 
branded product. You agree to comply with the terms and conditions contained in all such Third-Party 
Software licenses with respect to the applicable Third-Party Software. Where applicable, the URLs for 
sites where you may obtain source code for the Third Party Software can be found at 
http://www.seagate.com/support/by-topic/downloads/, or at http://www.lacie.com/support/ for LaCie 
branded product.  
 
2.  Product License.  Subject to your compliance with the terms of this EULA, Seagate grants you a 

=== Page 8 ===
 SAS HDD Firmware Update Instructions  07-Nov-2018 
 8 
personal, non-exclusive, non-transferable, limited license to install and use one (1) copy of the Software 
on one (1) device residing on your premises, internally and only for the purposes described in the 
associated documentation. Use of some third party software included on the media provided with the 
Product may be subject to terms and conditions of a separate license agreement; this license agreement 
may be contained in a “Read Me” file located on the media that accompanies that Product.  The 
Software includes components that enable you to link to and use certain services provided by third 
parties (“Third Party Services”).  Your use of the Third Party Services is subject to your agreement with 
the applicable third party service provider.  Except as expressly stated herein, this EULA does not grant 
you any intellectual property rights in the Product. Seagate and its suppliers reserve all rights not 
expressly granted to you.  There are no implied rights. 
 
2.1 Software.  You are also permitted to make a single copy of the Software strictly for backup and 
disaster recovery purposes.  You may not alter or modify the Software or create a new installer for the 
Software.  The Software is licensed and distributed by Seagate for use with its storage products only, 
and may not be used with non-Seagate storage product. 
 
3.  Restrictions.  You are not licensed to do any of the following: 
a. Create derivative works based on the Product or any part or component thereof, 
including, but not limited to, the Software; 
b. Reproduce the Product, in whole or in part; 
c. Except as expressly authorized by Section 11 below, sell, assign, license, disclose, or 
otherwise transfer or make available the Product, in whole or in part, to any third party; 
d. Alter, translate, decompile, or attempt to reverse engineer the Product or any part or 
component thereof, except and only to the extent that such activity is expressly 
permitted by applicable law notwithstanding this contractual prohibition;  
e. Use the Product to provide services to third parties; 
f. Take any actions that would cause the Software to become subject to any open source 
license agreement if it is not already subject to such an agreement; and 
g. Remove or alter any proprietary notices or marks on the Product. 
 
4.  Updates.  If you receive an update or an upgrade to, or a new version of, any Software (“Update”) 
you must possess a valid license to the previous version in order to use the Update.  All Updates 
provided to you shall be subject to the terms and conditions of this EULA.  If you receive an Update, you 

=== Page 9 ===
 SAS HDD Firmware Update Instructions  07-Nov-2018 
 9 
may continue to use the previous version(s) of the Software in your possession, custody or control.  
Seagate shall have no obligation to support the previous versions of the Software upon availability of an 
Update. Seagate has no obligation to provide support, maintenance, Updates, or modifications under 
this EULA.   
 
5.  NO WARRANTY.  THE PRODUCT AND THE THIRD-PARTY SOFTWARE ARE OFFERED ON AN “AS-IS” 
BASIS AND NO WARRANTY, EITHER EXPRESS OR IMPLIED, IS GIVEN.  SEAGATE AND ITS SUPPLIERS 
EXPRESSLY DISCLAIM ALL WARRANTIES OF ANY KIND, WHETHER STATUTORY, EXPRESS OR IMPLIED, 
INCLUDING, BUT NOT LIMITED TO, IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A 
PARTICULAR PURPOSE AND NON-INFRINGEMENT.  SEAGATE DOES NOT PROVIDE THE THIRD PARTY 
SERVICES AND MAKES NO WARRANTIES WITH RESPECT TO THE THIRD PARTY SERVICES.  YOUR USE OF 
THE THIRD PARTY SERVICES IS AT YOUR RISK. 
 
6.  EXCLUSION OF INCIDENTAL, CONSEQUENTIAL, AND CERTAIN OTHER DAMAGES.  TO THE MAXIMUM 
EXTENT PERMITTED BY APPLICABLE LAW, IN NO EVENT SHALL SEAGATE OR ITS LICENSORS OR SUPPLIERS 
BE LIABLE FOR ANY SPECIAL, INCIDENTAL, PUNITIVE, INDIRECT, OR CONSEQUENTIAL DAMAGES 
WHATSOEVER (INCLUDING, BUT NOT LIMITED TO, DAMAGES FOR LOSS OF PROFITS OR CONFIDENTIAL 
OR OTHER INFORMATION, FOR BUSINESS INTERRUPTION, FOR PERSONAL INJURY, FOR LOSS OF 
PRIVACY, FOR FAILURE TO MEET ANY DUTY INCLUDING OF GOOD FAITH OR REASONABLE CARE, FOR 
NEGLIGENCE, AND FOR ANY OTHER PECUNIARY OR OTHER LOSS WHATSOEVER) ARISING OUT OF OR IN 
ANY WAY RELATED TO THE USE OF OR INABILITY TO USE THE PRODUCT OR ANY PART OR COMPONENT 
THEREOF OR RELATED SERVICE OR ANY THIRD PARTY SERVICES, OR OTHERWISE UNDER OR IN 
CONNECTION WITH ANY PROVISION OF THE EULA, EVEN IN THE EVENT OF THE FAULT, TORT 
(INCLUDING NEGLIGENCE), MISREPRESENTATION, STRICT LIABILITY, BREACH OF CONTRACT, OR BREACH 
OF WARRANTY OF SEAGATE OR ITS LICENSORS OR SUPPLIERS, AND EVEN IF SEAGATE OR ITS LICENSOR 
OR SUPPLIER HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGES AND NOTWITHSTANDING ANY 
FAILURE OF THE ESSENTIAL PURPOSE OF THIS AGREEMENT OR ANY REMEDY.   
 
7.  LIMITATION OF LIABILITY.  NOTWITHSTANDING ANY DAMAGES THAT YOU MIGHT INCUR FOR ANY 
REASON WHATSOEVER, THE ENTIRE LIABILITY OF SEAGATE UNDER ANY PROVISION OF THIS EULA AND 
YOUR EXCLUSIVE REMEDY HEREUNDER SHALL BE LIMITED TO, AND IN NO EVENT WILL SEAGATE'S TOTAL 
CUMULATIVE DAMAGES EXCEED, THE FEES PAID BY THE LICENSEE TO SEAGATE FOR THE PRODUCT.  
ADDITIONALLY, IN NO EVENT SHALL SEAGATE'S LICENSORS OR SUPPLIERS BE LIABLE FOR ANY DAMAGES 
OF ANY KIND.   
 
8.  Privacy.  Seagate’s collection, use and disclosure of personally identifiable information in connection 

=== Page 10 ===
 SAS HDD Firmware Update Instructions  07-Nov-2018 
 10 
with your use of the Product is governed by Seagate’s Privacy Policy which is located at 
http://www.seagate.com/legal-privacy/privacy-policy/As further described in Seagate’s Privacy Policy, 
certain Products may include a Product dashboard which allows users to manage Product settings, 
including but not limited to use of anonymous statistical usage data in connection with personally 
identifiable information. You agree to Seagate’s collection, use, and disclosure of your data in 
accordance with the Product dashboard settings selected by you for the Product, or in the case of 
transfer as described in Section 11, you agree to the settings selected by the prior licensee unless or 
until you make changes to the settings.  
 
9.  Indemnification.  By accepting the EULA, you agree to indemnify and otherwise hold harmless 
Seagate, its officers, employees, agents, subsidiaries, affiliates, and other partners from any direct, 
indirect, incidental, special, consequential or exemplary damages arising out of, relating to, or resulting 
from your use of the Product or any other matter relating to the Product, including, without limitation, 
use of any of the Third Party Services.   
 
10.  International Trade Compliance.  The Software and any related technical data made available for 
download under this EULA are subject to the customs and export control laws and regulations of the 
United States (“U.S.”) and may also be subject to the customs and export laws and regulations of the 
country in which the download is contemplated.  Further, under U.S. law, the Software and any related 
technical data made available for download under this EULA may not be sold, leased or otherwise 
transferred to restricted countries, or used by a restricted end-user (as determined on any one of the 
U.S. government restricted parties lists, found at 
http://www.bis.doc.gov/complianceandenforcement/liststocheck.htm) or an end-user engaged in 
activities related to weapons of mass destruction including, without limitation, activities related to 
designing, developing, producing or using nuclear weapons, materials, or facilities, missiles or 
supporting missile projects, or chemical or biological weapons.  You acknowledge that you are not a 
citizen, national, or resident of, and are not under control of the governments of Cuba, Iran, North 
Korea, Sudan or Syria; are not otherwise a restricted end-user as defined by U.S. export control laws; 
and are not engaged in proliferation activities.  Further, you acknowledge that you will not download or 
otherwise export or re-export the Software or any related technical data directly or indirectly to the 
above-mentioned countries or to citizens, nationals, or residents of those countries, or to any other 
restricted end user or for any restricted end-use.   
 
11.  General.  This EULA between Licensee and Seagate is governed by and construed in accordance with 
the laws of the State of California without regard to conflict of laws principles.  The EULA constitutes the 
entire agreement between Seagate and you relating to the Product and governs your use of the Product, 
superseding any prior agreement between you and Seagate relating to the subject matter hereof.  If any 
provision of this EULA is held by a court of competent jurisdiction to be contrary to law, such provision 

=== Page 11 ===
 SAS HDD Firmware Update Instructions  07-Nov-2018 
 11 
will be changed and interpreted so as to best accomplish the objectives of the original provision to the 
fullest extent allowed by law and the remaining provisions of the EULA will remain in force and effect.  
The Product and any related technical data are provided with restricted rights.  Use, duplication, or 
disclosure by the U.S. government is subject to the restrictions as set forth in subparagraph (c)(1)(iii) of 
DFARS 252.227-7013 (The Rights in Technical Data and Computer Product) or subparagraphs (c)(1) and 
(2) of 48 CFR 52.227-19 (Commercial Computer Product – Restricted Rights), as applicable.  The 
manufacturer is Seagate.  You may not transfer or assign this EULA or any rights under this EULA, except 
that you may make a one-time, permanent transfer of this EULA and the Software to another end user, 
provided that (i) you do not retain any copies of the Software, the Hardware, the media and printed 
materials, Upgrades (if any), and this EULA, and (ii) prior to the transfer, the end user receiving this EULA 
and the Software agrees to all the EULA terms.  Any attempted assignment in violation of this Section is 
void.  Seagate, the Seagate logo, and other Seagate names and logos are the trademarks of Seagate.   
 
5.4.2016 
 
 
GNU LESSER GENERAL PUBLIC LICENSE 
Version 3, 29 June 2007 
Copyright © 2007 Free Software Foundation, Inc. <http://fsf.org/> 
Everyone is permitted to copy and distribute verbatim copies of this license document, but changing it is 
not allowed. 
This version of the GNU Lesser General Public License incorporates the terms and conditions of version 3 
of the GNU General Public License, supplemented by the additional permissions listed below. 
0. Additional Definitions. 
As used herein, “this License” refers to version 3 of the GNU Lesser General Public License, and the 
“GNU GPL” refers to version 3 of the GNU General Public License. 
“The Library” refers to a covered work governed by this License, other than an Application or a 
Combined Work as defined below. 
An “Application” is any work that makes use of an interface provided by the Library, but which is not 
otherwise based on the Library. Defining a subclass of a class defined by the Library is deemed a mode 
of using an interface provided by the Library. 

=== Page 12 ===
 SAS HDD Firmware Update Instructions  07-Nov-2018 
 12 
A “Combined Work” is a work produced by combining or linking an Application with the Library. The 
particular version of the Library with which the Combined Work was made is also called the “Linked 
Version”. 
The “Minimal Corresponding Source” for a Combined Work means the Corresponding Source for the 
Combined Work, excluding any source code for portions of the Combined Work that, considered in 
isolation, are based on the Application, and not on the Linked Version. 
The “Corresponding Application Code” for a Combined Work means the object code and/or source code 
for the Application, including any data and utility programs needed for reproducing the Combined Work 
from the Application, but excluding the System Libraries of the Combined Work. 
1. Exception to Section 3 of the GNU GPL. 
You may convey a covered work under sections 3 and 4 of this License without being bound by section 3 
of the GNU GPL. 
2. Conveying Modified Versions. 
If you modify a copy of the Library, and, in your modifications, a facility refers to a function or data to be 
supplied by an Application that uses the facility (other than as an argument passed when the facility is 
invoked), then you may convey a copy of the modified version: 
 a) under this License, provided that you make a good faith effort to ensure that, in the event an 
Application does not supply the function or data, the facility still operates, and performs 
whatever part of its purpose remains meaningful, or 
 b) under the GNU GPL, with none of the additional permissions of this License applicable to that 
copy. 
3. Object Code Incorporating Material from Library Header Files. 
The object code form of an Application may incorporate material from a header file that is part of the 
Library. You may convey such object code under terms of your choice, provided that, if the incorporated 
material is not limited to numerical parameters, data structure layouts and accessors, or small macros, 
inline functions and templates (ten or fewer lines in length), you do both of the following: 
 a) Give prominent notice with each copy of the object code that the Library is used in it and that 
the Library and its use are covered by this License. 
 b) Accompany the object code with a copy of the GNU GPL and this license document. 
4. Combined Works. 

=== Page 13 ===
 SAS HDD Firmware Update Instructions  07-Nov-2018 
 13 
You may convey a Combined Work under terms of your choice that, taken together, effectively do not 
restrict modification of the portions of the Library contained in the Combined Work and reverse 
engineering for debugging such modifications, if you also do each of the following: 
 a) Give prominent notice with each copy of the Combined Work that the Library is used in it and 
that the Library and its use are covered by this License. 
 b) Accompany the Combined Work with a copy of the GNU GPL and this license document. 
 c) For a Combined Work that displays copyright notices during execution, include the copyright 
notice for the Library among these notices, as well as a reference directing the user to the 
copies of the GNU GPL and this license document. 
 d) Do one of the following:  
o 0) Convey the Minimal Corresponding Source under the terms of this License, and the 
Corresponding Application Code in a form suitable for, and under terms that permit, the 
user to recombine or relink the Application with a modified version of the Linked 
Version to produce a modified Combined Work, in the manner specified by section 6 of 
the GNU GPL for conveying Corresponding Source. 
o 1) Use a suitable shared library mechanism for linking with the Library. A suitable 
mechanism is one that (a) uses at run time a copy of the Library already present on the 
user's computer system, and (b) will operate properly with a modified version of the 
Library that is interface-compatible with the Linked Version. 
 e) Provide Installation Information, but only if you would otherwise be required to provide such 
information under section 6 of the GNU GPL, and only to the extent that such information is 
necessary to install and execute a modified version of the Combined Work produced by 
recombining or relinking the Application with a modified version of the Linked Version. (If you 
use option 4d0, the Installation Information must accompany the Minimal Corresponding Source 
and Corresponding Application Code. If you use option 4d1, you must provide the Installation 
Information in the manner specified by section 6 of the GNU GPL for conveying Corresponding 
Source.) 
5. Combined Libraries. 
You may place library facilities that are a work based on the Library side by side in a single library 
together with other library facilities that are not Applications and are not covered by this License, and 
convey such a combined library under terms of your choice, if you do both of the following: 
 a) Accompany the combined library with a copy of the same work based on the Library, 
uncombined with any other library facilities, conveyed under the terms of this License. 
 b) Give prominent notice with the combined library that part of it is a work based on the Library, 
and explaining where to find the accompanying uncombined form of the same work. 
6. Revised Versions of the GNU Lesser General Public License. 
The Free Software Foundation may publish revised and/or new versions of the GNU Lesser General 
Public License from time to time. Such new versions will be similar in spirit to the present version, but 
may differ in detail to address new problems or concerns. 

=== Page 14 ===
 SAS HDD Firmware Update Instructions  07-Nov-2018 
 14 
Each version is given a distinguishing version number. If the Library as you received it specifies that a 
certain numbered version of the GNU Lesser General Public License “or any later version” applies to it, 
you have the option of following the terms and conditions either of that published version or of any 
later version published by the Free Software Foundation. If the Library as you received it does not 
specify a version number of the GNU Lesser General Public License, you may choose any version of the 
GNU Lesser General Public License ever published by the Free Software Foundation. 
If the Library as you received it specifies that a proxy can decide whether future versions of the GNU 
Lesser General Public License shall apply, that proxy's public statement of acceptance of any version is 
permanent authorization for you to choose that version for the Library. 
 
 
 
