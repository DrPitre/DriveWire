# DriveWire Protocol Version 4.0.0

The DriveWire Protocol Specification defines a set of communication messages that allow the Tandy/Radio Shack Color Computer (CoCo) to utilize the storage capacity of a modern personal computer (Server). This storage model gives the CoCo the appearance that it is directly connected to a large storage device, when in fact, connectivity is achieved using a serial cable connected from the Server to the CoCo’s built-in “Serial I/O” port.
There are distinct advantages in utilizing DriveWire as a storage medium:

- **Cost and space savings**: No additional hardware is needed for a CoCo to use mass storage; no floppy controller, hard drive controller or hard drives are required.
- **Remote operation**: The serial cable that tethers the CoCo to the Server can extend for some length, allowing the CoCo to be positioned a considerable distance from the Server.
- **Easy data management**: Virtual disks that reside on the Server can be easily copied, emailed or archived for backup purposes.

The essence of communication between the CoCo and Server is a documented set of uni- and bi-directional messages called transactions. Each transaction is composed of one or more packets, which are passed between CoCo and Server through a serial line connection. Using clever timing techniques on the CoCo, rates of up to 230,400 bps are reliably achievable.


# System Requirements

The Server shall be defined as a modern personal computer or hand-held device with sufficient mass storage and an RS-232 serial port that can be reliably driven at the desired (or in some cases, required) rate.

The CoCo shall be defined as any model of Color Computer 2 or greater, produced by Tandy/Radio Shack with at least 16K of RAM, or an FPGA device running a compatible Color Computer image (for instance CoCo3FPGA) as well as an appropriate operating environment that provides mass storage services (such as Disk BASIC or OS-9).


## Physical Interface Requirements

The physical cable connecting the CoCo to the Server is recommended to be no longer than 10 feet in length. USB to serial adapters generally work well. At a minimum, the serial line shall carry the following four wires:

Ground
Vcc
RD (Read Data)
WD (Write Data)

A 4 pin DIN connector shall be on one end of the cable which will mate to the jack on the back of the CoCo marked “Serial I/O”. The other end of the cable shall be either a DB-9 or DB-25 female connector which will mate to an appropriate serial port on the Server.

The following table shows the connections between the CoCo 4 pin DIN connector to either a 9-pin DB-9 serial connector or a 25-pin DB-25 serial connector.


[[img src=Coco_din.png]]

CoCo DIN connector | DB-9            | DB-25
---------------------------|----------------|---------
Pin 1 (CD)                  |Pin 3 (TD)    | Pin 2 (TD)
Pin 2 (RD)                  |Pin 3 (TD)    | Pin 2 (TD)
Pin 3 (GND)               |Pin 5 (GND) | Pin 7 (GND)
Pin 4 (TD)                  |Pin 2 (RD)    | Pin 3 (RD)

# Low Level Protocol

The communication protocol shall follow the RS-232 standard of 8-N-1 (1 start bit, 8 data bits, and 1 stop bit). For the Color Computer 2, the supported clock speed shall be .89MHz and the bit rate shall be 57,600 bits per second. For the Tandy Color Computer 3, the supported clock speed shall be 1.78MHz and the bit rate shall be 115,200 or 230,400 bits per second (rate determined by driver in use, with higher speeds negotiated automatically).

The transaction is the basis for exchanging information between CoCo and Server. All transactions consist of one or more packets of information, and are generally initiated by the CoCo.

Some transactions are uni-directional: from the CoCo to the Server. Other transactions are bi-directional. In a bi-directional transaction, both the CoCo and the Server shall send their respective responses within 250 milliseconds (1/4 of a second) of receiving the last packet from its peer, or else each shall presume a timeout condition and abort the transaction.

## System Transactions

### The RESET Transaction

This is a uni-directional transaction, and is performed by the CoCo as a notification to the Server when the CoCo is powered on or reset. The following packet is sent to the Server:

Byte      | Value
-----------|----------
0            | OP_RESET1 ($FF) or  OP_RESET2 ($FE) or  OP_RESET3 ($F8)


Upon receipt of the packet, the Server shall:
1\. Reset any statistical values related to read/write and sector transfer throughput for ALL drives.
2\. Flush all caches connected to the virtual drives.


### The INIT Transaction

This is a uni-directional transaction that the CoCo may send to indicate that a DW driver has initialized.

It currently does not cause any action on the server. See OP_DWINIT for the DW4 extended form, which is preferable.

Byte      | Value
-----------|----------
0            | OP_INIT ($49)

### The TERM Transaction

This is a uni-directional transaction that the CoCo may send to indicate that a DW driver has terminated.

It currently does not cause any action on the server.

Byte      | Value
-----------|----------
0            | OP_TERM ($54)

### The DWINIT Transaction

This bi-directional transaction allows the CoCo to inform the server of it's driver version or capabilities, and the server to respond with it's own version/capabilities. The exact meanings of the version byte are not yet defined. The only current use of this operation is by the OS9 driver. It performs this operation when initialized to determine whether it should load the DW4 specific extensions (virtual channel poller, etc). The DW3 server will not respond to DWINIT, whereas the DW4 server will. Any response is currently interpreted by the driver to indicate that the DW4 extensions should be loaded.

CoCo sends:

Byte      | Value
-----------|----------
0            | OP_DWINIT ($5A)
1            | Driver version/capabilities byte

Server response:

Byte      | Value
-----------|----------
0            | Server version/capabilities byte

### The TIME Transaction

This bi-directional transaction allows the CoCo to request time and date information from the Server:

Byte      | Value
-----------|----------
0            | OP_TIME ($23)

Server response:

Byte      | Value
-----------|----------
0            | Current year minus 1900 (0-255)
1            | Month (1-12)
2            | Day (1-31)
3            | Hour (0-23)
4            | Minute (0-59)
5            | Second (0-59)

### The NOP Transaction

This is a uni-directional transaction that can be ignored by the Server.

Byte      | Value
-----------|----------
0           | OP_NOP ($00)

## Disk Transactions

### The Read Transaction

This bi-directional transaction is initiated by the CoCo to request one 256 byte sector of data from the Server. When the CoCo desires to request a sector, it will send the following Read Request packet:

Byte      | Value
-----------|----------
0           | OP_READ ($52)
1           | Drive number (0-255)
2           | Bits 23-16 of 24-bit Logical Sector Number (LSN)
3           | Bits 15-8 of LSN
4           | Bits 7-0 of LSN

The drive number represents the disk image where the desired sector is located.

Upon receipt of the packet, the Server shall consult the appropriate disk image for the provided LSN and read that 256 byte sector. If an error occurs and the Server cannot read the specified sector, it shall return the following Read Failure packet:

Byte      | Value
-----------|----------
0           | Error code (any value other than 0)

If no error occurred on reading the sector from the Server file system, the Server shall return the following packet:

Byte      | Value
-----------|----------
0           | Error code of 0 (success)
1 - 2     | 16-bit checksum
3 - 258 | 256 bytes of valid sector data

Upon receipt of the Read Success, the CoCo shall:

1\. Compute the 16 bit checksum on the 256 bytes of sector data received from the Server.
2\. Compare the checksum it calculated against the checksum provided by the Server. If the checksums match, then the sector transfer is deemed a success and the transmission is terminated.

### The ReRead Transaction

In the event that the CoCo receives a Checksum Mismatch packet during the Read Transaction, the CoCo MAY send the following packet to the Server:

Byte      | Value
-----------|----------
0           | OP_REREAD ($72)
1           | Drive number
2           | Bits 23-16 of of 24-bit Logical Sector Number (LSN
3           | Bits 15-8 of LSN
4           | Bits 7-0 of LSN

Upon receiving this packet, the Server will attempt a retransmission of the requested sector.
At any time, the CoCo may suspend the re-reading of a sector if errors continue to accumulate, and the server will return to monitoring for additional commands.

### The Write Transaction

This bi-directional transaction allows the CoCo to send one 256 byte sector of data to the Server in order for it to be written to a specific virtual drive.

Byte      | Value
-----------|----------
0           | OP_WRITE ($57)
1           | Drive number (0-255)
2           | Bits 23-16 of of 24-bit Logical Sector Number (LSN
3           | Bits 15-8 of LSN
4           | Bits 7-0 of LSN
5-260    | 256 bytes of sector data to write
261       | Bits 15-8 of checksum (computed by CoCo)
262       | Bits 7-0 of checksum (computed by CoCo)

The Server shall implement a timeout of 250 milliseconds (1/4 second), in the event that the CoCo stops sending data. This allows the Server to recover from the Write Transaction state and return to processing other packets.
Once the Server receives this packet, it shall:

1\. Compute the 16 bit checksum over the 256 byte sector it received
2\. Compare the checksum that it computed against the checksum provided by the CoCo

Once the checksums have been compared, the Server shall acknowledge the transmission as follows:

Byte      | Value
-----------|----------
0           | 0 (checksum OK) or  243 (CRC error) or  some other error

The CoCo, upon receipt of the packet, will do one the following:

1\. If the error code received is 0 ($00), the CoCo will assume the transfer of the sector was a success and terminate the transmission.
2\. If the error code received is 243 (E$CRC), the CoCo MAY send the following packet:

### The Read Extended Transaction

This bi-directional transaction is initiated by the CoCo to request one 256 byte sector of data from the Server. When the CoCo desires to request a sector, it will send the following Read Extended Request packet:

Byte      | Value
-----------|----------
0           |  OP_READEX ($D2)
1         |  Drive number (0-255)
2         |  Bits 23-16 of of 24-bit Logical Sector Number (LSN)
3         |  Bits 15-8 of LSN
4         |  Bits 7-0 of LSN


The drive number is a value between 0-255, and represents the disk image where the desired sector is located.

Upon receipt of the packet, the Server shall consult the appropriate disk image for the provided LSN and read that 256 byte sector. If an error occurs and the Server cannot read the specified sector, it shall return the Read Failure packet:

Byte      | Value
-----------|----------
0-255   |  0 (256 bytes of 0)


If no error occurred on reading the sector from the Server file system, the Server shall return the following packet:

Byte      | Value
-----------|----------
0-255   |  256 bytes of valid sector data

Upon receipt of either the Read Success or the Read Failure packet, the CoCo shall:

1\. Compute the 16 bit checksum on the 256 bytes of sector data received from the Server.

2\. Send the computed checksum to the Server as follows:

Byte      | Value
-----------|----------
0         |   Bits 15-8 of the checksum (computed by CoCo)
1         |   Bits 7-0 of the checksum (computed by CoCo)

Upon receipt of the checksum packet, the Server shall take one of two actions:

**Action 1 – No Error Condition**&nbsp;: If the server acquired the requested sector without error, then it shall compute the 16 bit checksum on the 256 bytes of sector data sent to the CoCo and compare its calculated checksum against that of the CoCo.

If the compare yields a match occurs, then Server shall send the following packet to the CoCo:

Byte      | Value
----------|----------
0         | Error code (0 = no error)

If the compare does not yield a match, then Server shall send the following packet to the CoCo:

Byte      | Value
----------|----------
0         | Error code (243 = checksum mismatch)


Once either of these packets is received by the CoCo, the Read transaction is considered terminated.
**Action 2 – Error Condition**&nbsp;: If the Server was unable to acquire the requested sector due to an error, then the Server shall return an appropriate read error code:

Byte      | Value
-----------|----------
0           | Error code (1-242 or 244-255)


Once the Read Error packet is received by the CoCo, the Read transaction is considered terminated.
See Appendix A for a list of supported error codes, and Appendix B for the checksum algorithm used by the CoCo to generate the checksums.


### The ReRead Extended Transaction

In the event that the CoCo receives a Checksum Mismatch packet during the Read Transaction, the CoCo MAY send the following packet to the Server:

Byte      | Value
-----------|----------
0           |  OP_REREADEX ($F2)
1          |  Drive number (0-255)
2         | Bits 23-16 of 24-bit Logical Sector Number (LSN)
3         | Bits 15-8 of LSN
4         | Bits 7-0 of LSN

Upon receiving this packet, the Server will attempt a retransmission of the requested sector. The ReReadEx transaction is identical to the ReadEx transaction in every way other than its op code (aaw?)
At any time, the CoCo may suspend the re-reading of a sector if errors continue to accumulate, and the server will return to monitoring for additional commands.


### The ReWrite Transaction
Byte      | Value
-----------|----------
0           |  OP_REWRITE ($77)
1           |  Drive number (0-255)
2           |  Bits 23-16 of 24-bit Logical Sector Number (LSN)
3           |  Bits 15-8 of LSN
4           |  Bits 7-0 of LSN
5-260     | 256 bytes of sector data to write
261        | Bits 15-8 of checksum (computed by CoCo)
262        | Bits 7-0 of checksum (computed by CoCo)

The ReWrite operation is identical to the Write operation except in opcode (aaw?).


### The GetStat/SetStat Transaction


This uni-directional transaction is for informational purposes only and may not be supported in all client environments. Its inclusion into the protocol specification is mainly for the benefit of DriveWire-enabled OS-9 drivers that execute on the CoCo.

In such a driver, all GetStats/SetStats are passed to the Server via the OP_GETSTAT or OP_SETSTAT code, followed by a byte representing the GetStat/ SetStat code. The Server may wish to log this information, but does not act upon the packet itself.

Byte      | Value
-----------|----------
0           | OP_GETSTAT ($47) or  OP_SETSTAT ($53)
1         |  Drive Number (0-255)
2         |  GetStat or SetStat code

## Printing

DriveWire 3 introduced a special set of transactions to allow printing to the Server that it is connected to. The Server shall maintain a printer buffer where data bytes are added until a flush command is sent.

Upon receiving the flush command, the Server shall output the buffer in the format and location specified by the user. DW4 extensions to the printing system allow multiple types of output and arbitrary processing commands to be executed by the server upon a flush.

### Print Transaction

Using this uni-directional transaction, the CoCo notifies the Server that it has a single byte of data to add to the print queue.

Byte      | Value
-----------|----------
0           |  OP_PRINT ($50)
1          |  Byte of data to add to the queue

Upon receiving this packet, the Server shall add the passed byte to its internal print buffer.


### Print Flush Transaction

Using this uni-directional transaction, the CoCo notifies the Server that it has completed sending printer data and that the Server should send its print buffer to the printer.

Byte      | Value
-----------|----------
0           |  OP_PRINTFLUSH ($46)


## Virtual Serial Channels

DW4 adds 30 virtual channels (15 in versions prior to 4.2) which can be used to provide high level bidirectional communications between server and CoCo. Unlike the low level DW operations, communications using these virtual channels can be initiated by either side and packets need not be of a known size.
These channels are multiplexed over the the single physical serial connection, but act as separate serial connections in most ways and are independent of one another. They are designed to be presented as serial devices by the CoCo operating system, and currently the OS9 driver does exactly this: they are devices /N0 through /N14, with a special pseudo device '/N' that simply returns the first unused channel.
TODO: /Z window descriptor overview, /TERM and /MIDI variations
Each channel communicates with it's own virtual modem on the server side, which provides access to the new high level API commands. Much like a regular modem, these virtual modems have command states and 'online' or pass through states. When a port is opened, it's virtual modem will be in the command state.
The following low level operations are used to implement these virtual channels. For documentation of the API calls available via the virtual modems, see XXXX:


### The SERINIT Transaction

Using this uni-directional transaction, the CoCo notifies the Server that a particular channel should be initialized. It is equivalent to SERSETSTAT with status code SS.Open, and one of the two must be sent prior to any other operations on a given virtual channel.

**Note that DW4 server versions prior to 4.0.5 do not support SERINIT and SERTERM properly (they are NOPs in earlier versions). Use SERSETSTAT instead.**

Byte      | Value
-----------|----------
0           |  OP_SERINIT ($45)
1          |   Channel number to initialize (0-14 for virtual serial channels, or 128-142 for virtual window channels)*

    * 0-14 only in versions prior to 4.2


### The SERREAD / POLL Transaction

**Note: This operation as current implemented is known as OP_SERREAD, and is a fully compatible subset of the proposed OP_POLL operation.**

This bi-directional operation is sent by the CoCo to determine if incoming data is waiting for any of the virtual channels. The server will queue a practically unlimited amount of incoming data, but it is recommended to issue this command and respond to it's results as often as possible, while keeping the effect on overall system performance in mind, especially when in a multitasking environment.

For instance, the current OS9 driver may issue this command as frequently as every 50ms when interactive data (user typing) is detected on a virtual channel and no other use of the serial line is seen. The driver dynamically adjusts this rate to as slow as every 700ms when all channels are idle. When bulk data (file transfer, etc) is detected on a channel, the rate is adjusted so as to keep the local per channel buffer full (polling more often would simply waste cycles, less often would mean the local buffer may starve).

The server attempts to do load balancing between the channels in situations where multiple channels have data waiting by manipulating the SERREAD response. Channels with interactive data are given priority over channels with bulk data waiting. Each SERREAD that results in a channel being ignored causes that channel's wait counter to increment, and the channel with the highest wait counter is usually given preference in the SERREAD response. This prevents a single channel from monopolizing the serial line and attempts to ensure interactive traffic remains responsive even while other channels are transferring bulk data.

For simple single tasking applications where you wish to perform a single high level operation (such as the 'dw' word as implemented in cocoboot) it is often acceptable to simply loop sending SERREAD and interpreting its response as quickly as possible until the high level operation is complete.

Since this operation may happen very often (much more often than any other operation in a normal OS9 system), every effort has been made to make the response from the server small and easy for the CoCo side driver to interpret quickly. We want to stay out of the way of other operations as much as possible, so quick processing is critical. The response is fairly complex as it packs a lot of information into a couple bytes, but the most common patterns are easy to detect.

Sent by the CoCo:

Byte      | Value
-----------|----------
0           |  OP_SERREAD ($43)


Server response:

Byte      | Value
-----------|----------
0           |  Response byte 1
1           |  Response byte 2


Response byte 1 contains 3 pieces of information:

Byte 1 Bits      | Description
----------------------|----------
7-6                 |  Response mode. 0b00=VSerial mode, 0b10=VWindow mode
5                    |  Come again. 1 indicates that the server wishes CoCo to send another  SERREAD/POLL immediately if possible. **Currently always 0. **
4-0                 |  Option bits. Mode-dependent. **Currently always defined in the SERREAD format**, see next table

Option bits in SERREAD mode (Used by both VSerial and VWindow modes):

Bits      |  Description
-----------|----------
4         | Single/Multi byte response toggle (determines contents of response byte 2)
3 - 0    |  Virtual Channel indicator (relative channel number + 1)

Since currently we only implement the SERREAD mode and do not yet use the Come Again bit, the value of response byte 1 can be used to indicate the contents of byte 2 according to the following table.

Byte 1 value     | Meaning
-----------|----------
0               | There is no data or status waiting for any channel, ignore byte 2, end of operation.
1 to 15       | Byte 2 contains a single byte of data for VSerial channel (byte 1 - 1).  CoCo must add byte 2 to the input queue for channel (byte 1 - 1) and may  consider this channel to be in interactive mode.
16              | Byte 2 contains a VSerial status byte, see explanation below
17 - 31       | Byte 2 contains the number of bytes waiting for VSerial channel (byte 1 - 1 - 16).
128            |  There is no data or status waiting for any channel, ignore byte 2, end of operation.
129 to 143  |  Byte 2 contains a single byte of data for VWindow channel (byte 1 - 1 - 128).  CoCo must add byte 2 to the input queue for channel (byte 1 - 1 - 128) and may consider this channel to be in interactive mode.
144            |  Byte 2 contains a VWindow status byte, see explanation below
145 - 161   |  Byte 2 contains the number of bytes waiting for VWindow channel (byte 1 - 1 - 16 - 128).  Server is recommending that CoCo sends an OP_SERREADM to retrieve these bytes. CoCo may consider this channel to be in bulk transfer mode.

If byte 1 is 16 or 144, then byte 2 is a status byte and can be interpreted as follows:

Operation            | Bits 7-4   | Bits 3-0
Channel Closed   |  0000       |  Channel number, or 15 (1111) for all channels
Reboot Request  |  1111        |  1111

The OP_POLL/SERREAD response is a bit complex, but implementing a routine to handle the current SERREAD-only implementation is not:


     if $byte1 == 0 then exit

     else if $byte1


### The SERREADM Transaction

Using this bi-directional transaction, the CoCo requests a variable number of input bytes for a specific virtual channel.

CoCo sends:

Byte      | Value
-----------|----------
0           |  OP_SERREADM ($63)
1          |  Channel number (0-14) or (128-142)
2         | Number of  bytes requested (0-255)

Server responds:

Byte      | Value
-----------|----------
0-255    |  Variable; input bytes from requested channel's queue

Note that requesting more bytes than are present will result in a server error, and it will simply not respond for the timeout period, causing read error on the CoCo side. So, don't ask for more bytes than a SERREAD has told you exist in the queue, it will only bring sadness.


### The SERWRITE Transaction

This uni-directional transaction instructs the server to add a byte to the specified channel's output queue.

Note that the FASTWRITE operations are preferred in nearly every situation.

Byte      | Value
-----------|----------
0           |  OP_SERWRITE ($C3)
1           | Channel number (0-14) or (128-142)
2           | Data byte


### The FASTWRITE Transaction

This uni-directional transaction instructs the server to add a byte to the specified channel's output queue. The op code itself indicates the channel number, saving 33% of the overhead needed for a SERWRITE. We still waste 50% of the potential bandwidth, but FASTWRITE is fast enough to allow realtime MIDI playback on a CoCo 3 (which requires 32kbps effective throughput).

Byte      | Value
-----------|----------
0           |  OP_FASTWRITE ($80) + vserial channel number (0-14)
or 0       |  OP_FASTWRITE ($80) + vwindow channel number (128-142) - 128 + 32??? see aaw
1          |  Data byte



### The SERWRITEM Transaction

**Not implemented in current OS9 driver. Available in version 4.0.5 of the DW4 server.**

SERWRITEM allows the CoCo to send multiple bytes of output data to a specific virtual channel.

Byte      | Value
-----------|----------
0           |  OP_SERWRITEM ($64)
1           |  Channel number
2          | Number of data bytes following
3-258   | Data bytes


### The SERGETSTAT Transaction

Much like the OP_GETSTAT transaction, this uni-directional operation is sent when a getstat call is made on a particular channel. Currently for logging purposes only.

Byte      | Value
-----------|----------
0           |  OP_SERGETSTAT ($44)
1          |  Virtual channel number (0-14) or (128-142)
2          |  Getstat code


### The SERSETSTAT Transaction

This uni-directional transaction is sent by the CoCo when a setstat operation is performed on a virtual channel. There are 3 setstat codes that are interpretted by the server, and one that causes additional data to be read.

Byte      | Value
-----------|----------
0           |   OP_SERSETSTAT ($C4)
1          |   Virtual channel number (0-14) or (128-142)
2          |   setstat code
3 - 28   |  If byte 2 == $28 (SS.ComSt), 26 bytes containing the new device descriptor. Any other value in byte 2 means byte 2 is the end of the transaction.

If byte 2 is SS.ComSt (value $28), then the CoCo sends a total of 29 bytes. In all other cases, the CoCo sends a total of 3 bytes.

If byte 2 is SS.Open (value $29), then the channel is initialized and considered ready for I/O by the server.
**Please note: A SERINIT or SERSETSTAT with SS.Open must be sent prior to using any virtual channel!**

If byte 2 is SS.Close (value $2A), the channel is considered closed by the server. Any attached TCP sessions are terminated, any listening sockets controlled by this channel are terminated, etc.


### The SERTERM Transaction

This uni-directional operation is used to indicate that a particular channel should be closed, and any associated links be terminated. It is equivalent to SERSETSTAT with status code SS.Close.

**Note that DW4 server versions prior to 4.0.5 do not support SERINIT and SERTERM properly (they are NOPs in earlier versions). Use SERSETSTAT instead.**

Byte      | Value
-----------|----------
0           |  OP_SERTERM ($C5)
1           |  Virtual channel number (0-14) or (128-142)

## Named Objects

Named Objects are an extension found in DW4 server versions 4.0.4 and higher. They are currently only used by CoCoBoot but are available for any project that needs this type of thing. If you need a way to refer to specific entities that exist in permanent storage but don't want to implement a file system, named objects might be just the thing.

Basically, a named object is just a collection of bytes known by a particular name (a string of up to 255 bytes in length). Operations are provided for mounting and creating these objects by their name, and little else. The simplest example would be that the string itself is a file name on the server, but that is not a requirement of the protocol. The server sends back one of two results in response to any named object operation:

0, meaning it was unable to mount or create the requested object. or
a value from 1 to 255, which means the requested object is now mounted in the corresponding drive.

Mount fails if the object doesn't exist, whereas Create fails if it does exist. Create also fails if the desired object cannot be created, and both fail if the object ultimately cannot be mounted in a drive. This may be due to things unrelated to the object itself, perhaps there are no free drives, etc. The only result is 0 = sorry, didn't work.

If a named object is already mounted, the server may return the drive number already containing the object rather than remounting it.

DW4 provides mechanisms for associating specific names with arbitrary paths, which may be any path that is valid to a dw disk insert command, including local paths and a wide variety of URLs. You may also specify a local directory to be used as the source for named objects (specific mappings override matches in the named object directory).

Any mount resulting from a named object call is guaranteed valid **only until the next named object call is made**. This is an important control for some corner cases that can happen because we are in effect promising access to a specific named object, not just to a drive number. If we can't talk to that named object, we must at least ensure the I/O fails and doesn't get sent to some other object. So for the duration of this "lease" the server ensures all i/o to that drive # happens on that specific named object, and each named object call releases the previous lease and obtains a new one.


### Transaction OP_NAMEOBJ_MOUNT

Byte      | Value
-----------|----------
0           |  OP_NAMEOBJ_MOUNT ($01)
1         |   Length of name
2-258  |  Name


### Transaction OP_NAMEOBJ_CREATE

Byte      | Value
-----------|----------
0           |   OP_NAMEOBJ_CREATE ($02)
1          |  Length of name
2-258   |  Name

## Remote File Manager (RFM)

**Note: RFM is an unofficial extension, currently implemented only by the Swift host. It is documented here so that other hosts and guest drivers can implement it consistently. It is not part of the DW3/DW4 baseline and guests should not assume a given server supports it.**

RFM gives the CoCo direct access to files and directories on the Server's file system, rather than to fixed-size sector images. It was designed to back an OS-9 device driver, so its semantics (path descriptors, GetStat/SetStat codes, synthesized file descriptors) mirror the OS-9 RBF/SCF conventions rather than the disk-image sector model used elsewhere in this specification.

All RFM transactions share the same envelope:

Byte      | Value
-----------|----------
0           |  OP_RFM ($D6)
1           |  RFM sub-opcode (see table below)

The remaining bytes of the transaction, and the response, depend on the sub-opcode. Multiple files/directories may be open concurrently; each open is identified by a **path number** (0-255) chosen by the CoCo and passed as the first byte of every subsequent sub-opcode's payload. The Server maintains a per-path descriptor (host file handle, current position, open mode, resolved pathname) until the path is closed.

The Server confines all path resolution to a configured root directory (analogous to a device's root). Any pathname that would resolve outside of that root is rejected with error code 214 (E$FNA) rather than followed.

RFM error codes returned in the single-byte error responses are OS-9 style:

Code (dec) | Code (hex) | Meaning
-----------|------------|--------
0            | $00 | Success
211         | $D3  | E$EOF -- end of file
214         | $D6  | E$FNA -- file/path not accessible (includes root-escape attempts, permission denied, or path is a directory when a file was expected)
215         | $D7  | E$DNE -- directory not empty (delete of a non-empty directory)
216         | $D8  | E$PNNF -- path not found

### RFM sub-opcodes

Sub-opcode | Value | Name | Direction
-----------|-------|------|----------
1  | $01 | OP_RFM_CREATE | bi-directional
2  | $02 | OP_RFM_OPEN     | bi-directional
3  | $03 | OP_RFM_MAKDIR | bi-directional
4  | $04 | OP_RFM_CHGDIR | bi-directional
5  | $05 | OP_RFM_DELETE | bi-directional
6  | $06 | OP_RFM_SEEK     | bi-directional
7  | $07 | OP_RFM_READ     | bi-directional
8  | $08 | OP_RFM_WRITE   | uni-directional
9  | $09 | OP_RFM_READLN | bi-directional
10 | $0A | OP_RFM_WRITLN | uni-directional
11 | $0B | OP_RFM_GETSTT | bi-directional
12 | $0C | OP_RFM_SETSTT | uni-directional
13 | $0D | OP_RFM_CLOSE   | bi-directional

### Two directory contexts: data vs. execution

RFM tracks **two separate current-directory values per CoCo process**: a data directory (used to resolve relative pathnames for ordinary file access) and an execution directory (used to resolve relative pathnames when loading/executing code). This mirrors OS-9's distinction between a process's data and execution search paths. Every CREATE/OPEN/MAKDIR/CHGDIR/DELETE request carries a mode byte whose bit 2 ($04) selects which of the two directory contexts applies to that request; CHGDIR updates only the selected context. Each process's current directory falls back to its parent process's current directory if it has not set its own.

### OP_RFM_CREATE / OP_RFM_OPEN

CREATE opens a file for writing, creating it if it does not exist. OPEN opens an existing file or directory for reading (or read/write, per the mode byte). Both share the same wire format.

CoCo sends:

Byte      | Value
-----------|----------
0           |  OP_RFM ($D6)
1           |  OP_RFM_CREATE ($01) or OP_RFM_OPEN ($02)
2           |  Path number (0-255)
3           |  Process ID
4           |  Parent process ID
5           |  Mode byte (bit 7 $80 = directory open; bit 2 $04 = use execution directory instead of data directory; bits 1 and 3 relate to write access)
6-n       |  Pathname, terminated by a carriage return ($0D). High bit of each pathname byte is ignored.

Server response:

Byte      | Value
-----------|----------
0           |  Error code (0 = success)

If the mode byte indicates a directory open and the open succeeds, the Server synthesizes OS-9 style directory contents (see GETSTT/SS.FD below) for subsequent reads on that path.

### OP_RFM_MAKDIR

Creates a directory (including intermediate directories).

CoCo sends:

Byte      | Value
-----------|----------
0           |  OP_RFM ($D6)
1           |  OP_RFM_MAKDIR ($03)
2           |  Path number
3           |  Process ID
4           |  Parent process ID
5           |  Mode byte (bit 2 $04 = execution directory context)
6-n       |  Pathname, terminated by $0D

Server response:

Byte      | Value
-----------|----------
0           |  Error code (0 = success)

### OP_RFM_CHGDIR

Changes the CoCo process's current directory (data or execution, per the mode byte) to the given path. The pathname may use OS-9 multi-dot notation (".." = parent, "..." = grandparent, and so on -- N dots means N-1 levels up).

CoCo sends:

Byte      | Value
-----------|----------
0           |  OP_RFM ($D6)
1           |  OP_RFM_CHGDIR ($04)
2           |  Path number
3           |  Process ID
4           |  Parent process ID
5           |  Mode byte (bit 2 $04 = execution directory context)
6-n       |  Pathname, terminated by $0D

Server response:

Byte      | Value
-----------|----------
0           |  Error code (0 = success, 216 = path not found)

A pathname that would resolve above the Server's device root is clamped to that root rather than rejected.

### OP_RFM_DELETE

Deletes a file, or an empty directory.

CoCo sends:

Byte      | Value
-----------|----------
0           |  OP_RFM ($D6)
1           |  OP_RFM_DELETE ($05)
2           |  Path number
3           |  Process ID
4           |  Parent process ID
5           |  Mode byte (bit 2 $04 = execution directory context)
6-n       |  Pathname, terminated by $0D

Server response:

Byte      | Value
-----------|----------
0           |  Error code (0 = success, 214 = access denied/escapes root, 215 = directory not empty, 216 = not found)

### OP_RFM_SEEK

Sets the current file position for an already-open path.

CoCo sends:

Byte      | Value
-----------|----------
0           |  OP_RFM ($D6)
1           |  OP_RFM_SEEK ($06)
2           |  Path number
3           |  Bits 31-24 of the new 32-bit file position
4           |  Bits 23-16 of the new file position
5           |  Bits 15-8 of the new file position
6           |  Bits 7-0 of the new file position

Server response:

Byte      | Value
-----------|----------
0           |  Error code (always 0)

### OP_RFM_READ

Reads up to the requested number of bytes from the current file position and advances the position by the number of bytes actually returned.

CoCo sends:

Byte      | Value
-----------|----------
0           |  OP_RFM ($D6)
1           |  OP_RFM_READ ($07)
2           |  Path number
3           |  Bits 15-8 of the maximum number of bytes requested
4           |  Bits 7-0 of the maximum number of bytes requested

Server response:

Byte      | Value
-----------|----------
0           |  Bits 15-8 of the number of bytes returned (0 if at end of file or the path is unknown)
1           |  Bits 7-0 of the number of bytes returned
2-n       |  That many bytes of file data (omitted if the count is 0)

A returned count of 0 indicates end of file; the CoCo should treat this as E$EOF. The Server waits briefly (on the order of 2 milliseconds) after sending the byte count and before sending the data payload, to give a software (bit-banger) serial driver on the CoCo time to prepare its receive buffer.

### OP_RFM_WRITE

Writes bytes to the current file position and advances the position. This is a uni-directional transaction; the Server does not acknowledge it.

CoCo sends:

Byte      | Value
-----------|----------
0           |  OP_RFM ($D6)
1           |  OP_RFM_WRITE ($08)
2           |  Path number
3           |  Bits 15-8 of the byte count
4           |  Bits 7-0 of the byte count
5-n       |  Data bytes to write

### OP_RFM_READLN

Identical to OP_RFM_READ, except that the Server stops at the first line feed byte in the file (which it translates to a carriage return, $0D, in the returned data) or at the requested maximum, whichever comes first.

CoCo sends:

Byte      | Value
-----------|----------
0           |  OP_RFM ($D6)
1           |  OP_RFM_READLN ($09)
2           |  Path number
3           |  Bits 15-8 of the maximum number of bytes requested
4           |  Bits 7-0 of the maximum number of bytes requested

Server response:

Byte      | Value
-----------|----------
0           |  Bits 15-8 of the number of bytes returned (0 if at end of file or the path is unknown)
1           |  Bits 7-0 of the number of bytes returned
2-n       |  Line data, including the trailing $0D if a line end was found (omitted if the count is 0)

### OP_RFM_WRITLN

Writes a single line to the current file position. This is a uni-directional transaction; the Server does not acknowledge it. The Server writes bytes up to (but not including) the first carriage return ($0D) or $FF byte in the supplied data, translating a terminating $0D to a line feed ($0A) on disk; any bytes after the terminator are considered stale buffer contents and discarded.

CoCo sends:

Byte      | Value
-----------|----------
0           |  OP_RFM ($D6)
1           |  OP_RFM_WRITLN ($0A)
2           |  Path number
3           |  Bits 15-8 of the byte count
4           |  Bits 7-0 of the byte count
5-n       |  Data bytes, normally terminated by $0D

### OP_RFM_GETSTT

Retrieves status information about an open path. The request carries a GetStat code using the same SS.* code space as OP_GETSTAT/OP_SETSTAT elsewhere in this specification.

CoCo sends:

Byte      | Value
-----------|----------
0           |  OP_RFM ($D6)
1           |  OP_RFM_GETSTT ($0B)
2           |  Path number
3           |  GetStat code

Currently supported GetStat codes:

**SS.Size ($02)** -- returns the file's size as a 4-byte big-endian value. No further bytes are sent by the CoCo.

Byte      | Value
-----------|----------
0-3       |  File size, 32-bit big-endian

**SS.Pos ($05)** -- returns the file's current position as a 4-byte big-endian value. No further bytes are sent by the CoCo.

Byte      | Value
-----------|----------
0-3       |  Current file position, 32-bit big-endian

**SS.EOF ($06)** -- returns whether the path is at end of file. No further bytes are sent by the CoCo.

Byte      | Value
-----------|----------
0           |  0 (not at EOF) or 211/E$EOF (at EOF)

**SS.FD ($0F)** -- returns a synthesized OS-9 file descriptor for the path (see "Synthesized file descriptors" below). After the initial 4-byte GETSTT request, the CoCo sends 2 more bytes and the Server replies with the requested number of descriptor bytes (capped at 256):

Byte      | Value
-----------|----------
0           |  Bits 15-8 of the number of bytes requested
1           |  Bits 7-0 of the number of bytes requested

Server response:

Byte      | Value
-----------|----------
0-n       |  Up to 256 bytes of synthesized file descriptor data

**SS.FDInf ($20)** -- returns a synthesized OS-9 file descriptor for a directory entry previously returned by SS.FD, identified by its LSN rather than by an open path. After the initial 4-byte GETSTT request, the CoCo sends 4 more bytes:

Byte      | Value
-----------|----------
0           |  Bits 23-16 of the LSN
1           |  Unused
2           |  Bits 15-8 of the LSN
3           |  Bits 7-0 of the LSN

Server response:

Byte      | Value
-----------|----------
0-255   |  256 bytes of synthesized file descriptor data

Any other GetStat code is accepted but produces no response payload.

### OP_RFM_SETSTT

Currently a no-op: the Server consumes only the 2-byte OP_RFM/sub-opcode header and sends no response and expects no further bytes from the CoCo.

Byte      | Value
-----------|----------
0           |  OP_RFM ($D6)
1           |  OP_RFM_SETSTT ($0C)

### OP_RFM_CLOSE

Closes a path and releases its descriptor.

CoCo sends:

Byte      | Value
-----------|----------
0           |  OP_RFM ($D6)
1           |  OP_RFM_CLOSE ($0D)
2           |  Path number

Server response:

Byte      | Value
-----------|----------
0           |  Error code (always 0)

### Synthesized directory listings

When a path is opened as a directory (mode bit $80 set on OPEN), the Server synthesizes its contents as a sequence of 32-byte OS-9 style directory entries readable via OP_RFM_READ:

Byte      | Value
-----------|----------
0-28     |  Entry name, up to 29 characters, with the high bit of the last character set to mark the end of the name
29-31   |  A 24-bit LSN identifying this entry, for use with GETSTT/SS.FDInf

The first two entries are always "." (the directory itself) and ".." (its parent); at the Server's device root, ".." refers back to the root itself. The LSNs used here are Server-assigned identifiers for host paths and bear no relation to physical sector numbers; they exist only so that SS.FDInf can be used to retrieve a file descriptor for a directory entry without opening it as a path.

### Synthesized file descriptors

GETSTT/SS.FD and GETSTT/SS.FDInf both return a file descriptor sector synthesized from the underlying host file's attributes, in OS-9 FD format:

Byte      | Value
-----------|----------
0           |  FD.ATT: attribute byte. Bit 7 ($80) set if a directory. Bits 0-5 are owner read/write/execute and public read/write/execute, derived from the host file's POSIX permissions.
1-2       |  FD.OWN: owner ID (always 0)
3-7       |  FD.DAT: last modification date/time (year-1900, month, day, hour, minute)
8           |  FD.LNK: link count (always 1)
9-12     |  FD.SIZ: file size, 32-bit big-endian
13-15   |  FD.Creat: creation date (year-1900, month, day)
16-n     |  FD.SEG: segment list; always zero, since RFM files have no physical sector allocation

## WireBug Mode

**Note that WireBug is not yet implemented. Looking for a cool project??**

DriveWire 3 introduced a special set of transactions to facilitate remote debugging between a CoCo and the Server that it is connected to. This feature, known as WireBug, allows the transfer of register information and memory from the CoCo to the Server. Once the CoCo has entered WireBug mode, it can receive messages initiated by the server.

Because of the nature of the protocol and to increase accuracy and efficiency, WireBug uses a fixed packet size of 24 bytes and reserves the last byte as an 8- bit checksum byte.



### Enter WireBug Mode Transaction

Using this uni-directional transaction, the CoCo notifies the Server that it has entered WireBug remote debugging mode.

Byte      | Value
-----------|----------
0          |  OP_WIREBUG_MODE ($42)
1          |  CoCo Type ($02 = CoCo 2, $03 = CoCo 3)
2          |  CPU Type ($08 = 6809, $03 = 6309)
3-23     |  Reserved for future definition

Once the CoCo has sent this packet, it shall go into WireBug Mode where it will wait for commands from the Server.

Along with notifying the Server that the CoCo is in WireBug mode, the packet also communicates the CoCo and processor type. The Server should use this information as a cue to what type of processor is in the CoCo, and adjust accordingly.

### Read Registers Transaction

_Server Initiated_

Using this bi-directional transaction, the Server requests the contents of the registers from the CoCo.

Byte      | Value
-----------|----------
0          |  OP_WIREBUG_READREGS ($52)
1-22     |  0
23        |  Checksum

Upon receipt of the packet, the CoCo shall compute the checksum of bytes 0-22 and compare its computed value against byte 23. If a checksum match does not occur, then the CoCo shall disregard the packet and send the following response packet:

Byte      | Value
----------|----------
0         | Error code (243 = checksum mismatch)

Upon receipt of this packet, the Server may elect to restart the transaction.

If a checksum match occurs, the CoCo shall respond with the following packet:

Byte      | Value
-----------|----------
0          |  OP_WIREBUG_READREGS ($52)
1          |  Value of DP register
2          |  Value of CC register
3          |  Value of A register
4          |  Value of B register
5          |  Value of E register
6          |  Value of F register
7          |  Value of X register (hi)
8          |  Value of X register (lo)
9          |  Value of Y register (hi)
10        |  Value of Y register (lo)
11        |  Value of U register (hi)
12        |  Value of U register (lo)
13        |  Value of MD register
14        |  Value of V register (hi)
15        |  Value of V register (lo)
16        |  Value of SP register (hi)
17        |  Value of SP register (lo)
18        |  Value of PC register (hi)
19        |  Value of PC register (lo)
20-22   |  Not yet defined
23        |  Checksum

Upon receipt of the packet, the Server shall compute the checksum of bytes 0-22 and compare its computed value against byte 23. If a match occurs, the Server shall accept the packet’s payload. If a match does not occur, then the Server may elect to restart the transaction.

### Write Registers Transaction

_Server Initiated_

Using this bi-directional transaction, the Server requests that the contents of the packet passed to the CoCo be written to its registers.

The following packet shall be sent to the CoCo:

Byte      | Value
-----------|----------
0         |  OP_WIREBUG_WRITEREGS ($72)
1         |  Value of DP register
2         |  Value of CC register
3         |  Value of A register
4         |  Value of B register
5         |  Value of E register
6         |  Value of F register
7         |  Value of X register (hi)
8         |  Value of X register (lo)
9         |  Value of Y register (hi)
10       |  Value of Y register (lo)
11       |  Value of U register (hi)
12       |  Value of U register (lo)
13       |  Value of MD register
14       |  Value of V register (hi)
15       |  Value of V register (lo)
16       |  Value of SP register (hi)
17       |  Value of SP register (lo)
18       |  Value of PC register (hi)
19       |  Value of PC register (lo)
20-22  |  Not yet defined
23      |  Checksum

Upon receipt of the packet, the CoCo shall compute the checksum of bytes 0-22 and compare its computed value against byte 23. If a match occurs, the CoCo shall accept the packet’s payload, update its registers and send the following response packet:

Byte      | Value
-----------|----------
0          | Error code (0 = no error)


If a checksum match does not occur, then the CoCo shall disregard the packet and send the following response packet:

Byte      | Value
-----------|----------
0          | Error code (243 = checksum mismatch)

Upon receipt of this packet, the Server may elect to restart the transaction.


### Read Memory Transaction

_Server Initiated_

This bi-directional transaction is sent from the Server to the CoCo. The Server uses this transaction to obtain memory values from the CoCo.

The following packet is sent from the Server:

Byte      | Value
-----------|----------
0         |  OP_WIREBUG_READMEM ($4D)
1         |   Hi-byte of starting memory location
2         |   Lo-byte of starting memory location
3         |  Count (0)
4-22    |  Don't Care
23       |  Checksum

Upon receipt of the packet, the CoCo shall compute the checksum of bytes 0-22 and compare its computed value against byte 23. If a checksum match does not occur, then the CoCo shall disregard the packet and send the following response packet:

Byte      | Value
-----------|----------
0         | Error code (243 = checksum mismatch)


Upon receipt of the Checksum Mismatch Packet, the Server may elect to restart the transaction.

If a match occurs, the CoCo shall validate the memory request. If byte 3 (count) is not between 1 and 22, then the CoCo shall send the following response packet:

Byte      | Value
-----------|----------
0           |  Error code (16 = illegal number)

If the byte count is between 1 and 22, then the CoCo shall accept the packet’s payload and send the following response packet:

Byte      | Value
-----------|----------
0          | OP_WIREBUG_READMEM ($4D)
1..n      | Memory contents from start to end
n+1..22 | Don't care
23        |  Checksum

Upon receipt of the packet, the Server shall compute the checksum of bytes 0 to 22 and compare its computed value against byte 23. If a match occurs, the Server shall accept the packet’s payload. If a match does not occur, then the Server may elect to restart the transaction.


### Write Memory Transaction

_Server Initiated_

This bi-directional transaction is sent from the Server to the CoCo. The Server uses this transaction to modify the contents of the CoCo’s memory.

The following packet is sent from the Server:

Byte      | Value
-----------|----------
0           |  OP_WIREBUG_WRITEMEM ($6D)
1          | Hi-byte of starting memory location
2          | Lo-byte of starting memory location
3          | Count (n bytes where 0
4-22     | Bytes to be modified
23        | Checksum

Upon receipt of the packet, the CoCo shall compute the checksum of bytes 0-22 and compare its computed value against byte 23. If a checksum match does not occur, then the CoCo shall disregard the packet and send the following response packet:

Byte      | Value
-----------|----------
0           | Error code (243 = checksum mismatch)

If a match occurs, the CoCo shall validate the memory request. If byte 3 (count) is not between 1 and 19, then the CoCo shall send the following response packet:

Byte      | Value
-----------|----------
0           |  Error code (16 = illegal number)

If the byte count is between 1 and 19, then the CoCo shall accept the packet’s payload, update its memory with the contents from the Server, and send the following response packet:

Byte      | Value
-----------|----------
0           | Error code (0 = no error)


### Continue Execution Transaction

_Server Initiated_

This uni-directional transaction is sent from the Server to the CoCo. The Server uses this transaction to notify the CoCo that it should continue executing normally.

The following packet is sent from the Server:

Byte      | Value
-----------|----------
0           |  OP_WIREBUG_GO ($47)
1 - 23    |  Don't care

Upon receiving this packet, the CoCo shall exit WireBug Mode and commence execution. The Server shall commence responding to CoCo-initiated DriveWire transactions.


# High Level APIs

With the introduction of virtual channels, DriveWire 4 brings a second type of communication between the CoCo and server. This is accomplished by sending commands over one of the virtual channels to its dedicated virtual modem. Several command sets are available, each dedicated to a certain type of task.

Unlike the low level API, commands and responses using the high level APIs do not necessarily have fixed sizes, nor are they required to complete within a specific time window. These constraints are met by the underlying operations that implement the virtual channel, freeing the programmer or user from worrying about such details. The virtual channels can be used very much like a regular serial port connected to a regular modem, in fact there is a Hayes compatible command set for using the virtual channel exactly like a modem with regular telecom software.


## Hayes compatible command set


The virtual modem implements a complete Hayes compatible command set. This allows practically any existing telecommunications software to become "internet capable" (Terminal emulators, BBSes, and UUCP have all been used successfully). Simply use an IP address or hostname and port in the place of a phone number, i.e. ATDT127.0.0.1:6800 or ATDmybbs.somewhere.net:4000. Echo, command result format and other Hayes parameters work exactly as they would with a standard Hayes modem.

When a Hayes command is sent over the virtual channel, the virtual modem interprets it and either responds with a standard Hayes type response (exact format determined by current modem settings, i.e. OK/ERROR or numeric results) or goes into "online mode" just as a regular modem would do in response to ATD commands.
There currently is no 'escape sequence' such as +++ to exit 'online mode'. Instead, the modem will return to command mode when the TCP/IP connection is closed.


### Commands fully supported

    ATA
    A/
    ATD
    ATE
    ATH
    ATI
    ATO
    ATQ
    ATSxx=xx
    ATSxx?
    ATV
    ATZ
    AT&F
    AT&V


### Commands allowed but not processed

(they have no meaning in our implementation)

    ATB
    ATL
    ATM
    ATN
    ATX


### S Registers fully implemented

(all 256 can be set and queried, but these are actually used by the emulation)

    S0, S1, S2, S3, S4, S5, S12


[[img src=Dw4_hayes.png]]


## 'dw' commands

The various 'dw' commands allow you to control and configure every aspect of the server. These commands can be sent to the server in a number of ways, including the dw command utility in OS9 and the DriveWire User Interface graphical tool.



[[img src=Dw4_ui_command.png]]

When the virtual modem receives a dw command, it passes that command to the instance handler responsible for this CoCo. The handler returns a result that consists of a status byte, a status message, and possibly a result message which may be quite large.



The virtual modem returns a status line containing the status value as ascii text, a space, and the status text. It is expected that this line will be interpreted by the calling code but it may be shown to the user, especially for error responses. A status value of 0 indicates that the command was successful. The status text in a non 0 result may contain information that is useful to the user, for instance explaining why a command is not valid or suggesting a syntax correction.

If the status code is 0, one or more lines of text may follow the status line. Generally these are intended to be shown verbatim to the user (or written to standard output for use in a piped command).

When the status line and any additional response lines have been transmitted the server will close the channel. To send an additional dw command you must open a new channel. By closing the channel at the end out output we cause OS9 to return an EOF condition to the calling program. This makes determining the end of output very simple and allows piping the result text into a local file easily. Since some dw commands return entire files themselves, this mechanism is a critical part of making file transfer over the dw channels simple.

Non OS9 implementations may wish to use an EOF mechanism if such a thing is available, or may simply want to do an input loop using SERREAD and SERREADM until a SERREAD indicating that the channel has been closed is received.

For a complete list of result codes, see Appendix D.

[[img src=Dw4_os9_command.png]]



An example 'dw' command exchange:

  1. virtual device /N is requested open by the 'dw' utility using an OS9 syscall.
  2. the /N pseudo device returns real device /N2, calls SERSETSTAT SS.Open on /N2, and returns a file handle to the 'dw' utility.
  3. the dw utility writes the string:


        dw disk show\n

  4. on the server, the virtual modem detects a dw command and passes it to the proto handler for the connected instance
  5. the proto handler returns a result to the virtual modem containing a status byte of 0, status text of "OK" and result text with current disk drive details.
  6. the virtual modem writes:


        0 OK\n
        Current DriveWire disks:\n
        \n
         X0  E:/cocodisks/named/snd\n
         X255 E:/cocodisks/named/CoCoBoot.isave\n

  7. the dw utility reads this data from the /N2 device. because the status line begins with '0 ' it knows the command succeeded, and so it simply loops writing the additional lines to the screen.
  8. the virtual modem closes the channel when it detects all lines have been read.
  9. the dw utility gets an EOF condition and exits.



All commands may be abbreviated to their shortest unique form. For help on any dw command, enter the portion you know followed by&nbsp;?.

Examples:


    dw disk ?  : show help for 'dw disk'
    dw d sh    : abbreviated form of 'dw disk show'


### dw config

The dw config commands allow you to view, edit, and save the running instance configuration. Note that these commands all apply only to instance specific settings. Server wide settings cannot be changed from within a particular instance, however they can be viewed using the dw server show config command.

#### dw config save

Usage: dw config save


Requests that the server write the current running configuration to the configuration file on disk. Note that this command is typically not necessary as the server runs in 'autosave' mode by default (this mode is required if you will be using the GUI client).


#### dw config set

Usage: dw config set item \[value\]


Sets or clears a particular configuration item.

Examples:


    dw config set HDBDOSMode true        : Set the item 'HDBDOSMode' to equal 'true'
    dw config set TelnetBannerFile       : Remove/clear the item 'TelnetBannerFile'


#### dw config show

Usage:   dw config show \[item\]

Displays the current value of specified item, or lists entire configuration if item is not specified.


### dw disk

Usage: dw disk \[command\]

The dw disk commands allow you to manage the DriveWire virtual drives.

#### dw disk show

Usage: dw disk show \[\#\]

Show current disk details

The dw disk show command is a useful tool for quickly determining the status of the virtual disk drives that DW4 provides. It can be abbreviated as "dw d sh".

Examples:


    dw disk sh         : show overview of the currently loaded drives
    dw disk sh 0       : show details about disk in drive 0


#### dw disk eject

Usage: dw disk eject \[\# | al\l]

Eject disk from drive #

This command lets you eject disk images from the virtual drives. The special word 'all' may be used in place of a drive number to eject all disks.

Examples:


    dw disk eject 1        : eject disk from virtual drive 1
    dw disk eject all      : unload all virtual drives


#### dw disk insert

Usage: dw disk insert \[\# path\]

Load disk into drive #

The disk insert command is used to load a disk image into a virtual drive. The path argument can be either a local file path or a URI. See the wiki information on paths for more details.

Examples:


    dw disk in 0 c:\cocodisks\mydisk.dsk  : load disk into drive 0


#### dw disk reload

Usage: dw disk reload \[\# | all\]

Reload disk in drive #

This command tells the server to reload a buffer from it's current source path. This will overwrite any unsaved changes in the buffer.

Example:


    dw d reload 5  : reload disk image for drive 5


#### dw disk write

Usage: dw disk write \[\# \[path\]\]

Write disk image

The dw disk write command can do different operations depending on the arguments you provide. In the simplest form, with only a drive number specified, it will write a drive's current buffer contents back to the source path. You can specify a different path if you'd like to write the buffer to somewhere else. This will create the destination if it does not exist, or overwrite the destination if it does. The dw disk write command is especially handy for writing disk images that originally were loaded from read only sources to alternate, writable locations.

Examples:


    dw disk write 9                 : write buffer for drive 9 to the source path
    dw d w 9 /home/coco/backup1.dsk : write drive 9 buffer to an alternate path


#### dw disk create

Usage: dw disk create \[\# \[path\]\]

Create new disk image

This command will create a new disk image. If given, a 0 byte file will be created at the specified path and mounted in the specified drive. If no path is specified the image will be held in memory only (but can be written to disk at any time using the dw disk write command).

Examples:


    dw disk create 3             : create new image for drive 3 in memory
    dw d c 0 c:\coco\newdisk.dsk : create new .dsk in drive 0


#### dw disk set

Usage: dw disk set \[\# param \[val\]\]

Set disk parameters

The disk set command allows you to set or unset a variety of parameters that control the operation of a virtual disk drive. For information on the various parameters available, see the relevant wiki topic.

Examples:


    dw disk set 1 writeprotect true     : Enable an option for drive 1
    dw d set 1 sizelimit                : Unset a parameter on drive 1.


#### dw disk dos

Usage: dw disk dos \[command\]

The various dw disk dos commands allow manipulation of DECB formatted disk image contents.

##### dw disk dos add

Usage: dw disk dos add \[\# path\]

Add specified file to the DECB disk image in drive #.

##### dw disk dos dir

Usage: dw disk dos dir \[\#\]

Show directory of the DECB disk image in drive #.

##### dw disk dos format

Usage: dw disk dos format \[\#\]

Format the image in drive # with a DECB filesystem.

##### dw disk dos list

Usage: dw disk dos list \[\# filename\]

Lists contents of specified filename from DECB image in specified drive #.


### dw log

#### dw log show

Usage: dw log show \[\#\]

Show the specified number of lines from the server log (defaults to 20 if not specified).


### dw midi

#### dw midi output

Usage: dw midi output \#

Set midi output to device # (as enumerated by dw midi status).


#### dw midi status

Usage: dw midi status

Show current MIDI status


#### dw midi synth

##### dw midi synth bank

##### dw midi synth instr

##### dw midi synth lock

##### dw midi synth profile

##### dw midi synth show

###### dw midi synth show channels

###### dw midi synth show instr

###### dw midi synth show profiles

##### dw midi synth status


### dw net

#### dw net show

Show current network connections.

### dw port

#### dw port close

#### dw port open

#### dw port show


### dw server

#### dw server dir

#### dw server help

#### dw server list

#### dw server print

#### dw server show

##### dw server show handlers

##### dw server show threads

##### dw server show config

#### dw server status

#### dw server turbo



## Networking commands

The networking API provides high level TCP/IP session establishment. There is some redundancy with the Hayes AT command set, but it is hoped that the networking API maybe someday be used to interface with a variety of devices in addition to DriveWire, where the AT command set would not make sense.


### tcp

Currently the commands are limited to TCP connection management, but it is expected that they will be expanded to provide UDP, ICMP and other additional functionality at some point.



#### tcp connect

Usage: tcp connect \[host\] \[port\]

Attempts to establish connection to specified host:port. Returns standard DW response line (i.e. 0 OK\n or XXX Error message\n). If response is OK then channel is now connected and all future read/write is done to the new tcp connection. If the connection is closed by the remote end, the channel will be closed, and vice versa.

#### tcp listen

Usage: tcp listen \[port\] \[zero or more flags\]

Instructs server to begin listening on the specified TCP port. Returns a standard DW response line. If the socket is successfully opened for listening the result will be 0, and in the future if a client connects, that connection will be announced on this channel in the form:

con# local_port host_address\n

The con# is a unique identifier for this connection, and is typically passed to a forked process so it may be specified in a tcp join command. Note that the local port number is included in the connection announcement. This is because it is legal (and normal) to send several 'tcp listen' commands on a single channel. By reading the local port in the connection announcement, your server process knows which port has a new connection and can spawn the correct handling code.



#### tcp join

Usage: tcp join \[con\#\]

Connects this channel to the specified connection. A standard DW response line is returned. If the status code is 0, this channel is now connected and all future read/write will occur on the joined TCP connection.


#### tcp kill

Usage: tcp kill \[con\#\]

Closes the specified connection. May be used by a listening process in place of a join if the connection is not desired, or may be used at any time to severe a connection already in progress.


## UI commands

These commands are fairly equivalent to the 'dw' commands, but return machine readable output and provide certain functionality only applicable to the DW user interface. If you are writing software that controls the DW server, you may find these commands are better suited than the user oriented 'dw' versions.

### ui instance

#### ui instance attach

#### ui instance config

##### ui instance config set

##### ui instance config show

#### ui instance disk

##### ui instance disk show

##### ui instance disk status

#### ui instance midistatus

#### ui instance printerstatus

#### ui instance reset

#### ui instance status

### ui server

#### ui server config

##### ui server config freeze

##### ui server config serial

##### ui server config set

##### ui server config show

##### ui server config write

#### ui server file

##### ui server file defaultdir

##### ui server file dir

##### ui server file info

##### ui server file roots

#### ui server show

##### ui server show errors

##### ui server show help

##### ui server show instances

##### ui server show localdisks

##### ui server show log

##### ui server show mididevs

##### ui server show net

##### ui server show serialdevs

##### ui server show status

##### ui server show synthprofiles

##### ui server show topics

##### ui server show version

#### ui server terminate

### ui sync


# Appendix A. Error Codes

The error codes used by the Server to indicate an error condition mirror the same codes used in OS-9. Here is a list of codes that should be used and the conditions that will trigger them:
• $F3 – CRC Error (if the Server’s computed checksum doesn’t match a write request from the CoCo)
• $F4 – Read Error (if the Server encounters an error when reading a sector from a virtual drive)
• $F5 – Write Error (if the Server encounters an error when writing a sector)
• $F6 - Not Ready Error (if the a command requests accesses a non- existent virtual drive)

# Appendix B. DriveWire Checksum Algorithm

Even though DriveWire has been shown to provide very stable and reliable communications between CoCo and Server, a checksum algorithm has been employed to bring an added level of data integrity.
This checksum algorithm (new in DW3) is simpler and significantly better at tracking bit errors than the CRC algorithm employed in DriveWire Version 1, which used a fast but weak CRC method.
Designers of DriveWire Server software should implement the following checksum algorithm (presented in C source code) for computing a checksum for all sectors read and written to/from the CoCo.


     int calChecksum(unsigned char *ptr, int count)
     {
       short Checksum = 0;
       while(--count)
       {
         Checksum += *(ptr++);
       }
       return (Checksum);
     }


Note that WireBug uses an 8-bit rather than a 16-bit checksum.

# Appendix C. Table of all DW op codes
Op Code                           | Value         | ASCII  | In DW Version | Notes
----------------------------------------|------------------|------------|-----------------------|---------
OP_NOP                           | 0    (0x00)   | | DW 3          |
OP_NAMEOBJ_MOUNT    | 1     (0x01)   | | DW 4.0.3    |
OP_NAMEOBJ_CREATE  | 2      (0x02)   |  |DW 4.0.3     |
Reserved for future named obj use | 3-15 (0x03 - 0x0F) | N/A  |
OP_TIME                         | 35    (0x23)  | #  | DW 3 |
OP_AARON                     |  65   (0x41) | A  |  N/A  |
OP_WIREBUG_MODE     |  66   (0x42) |  B  | N/A  |
OP_SERREAD                |  67   (0x43) |  C  | DW 4.0.0 |
OP_SERGETSTAT          |  68   (0x44) |  D  | DW 4.0.0 |
OP_SERINIT                  |  69   (0x45)  | E  |  DW 4.0.5 |
OP_PRINTFLUSH          |  70   (0x46)  | F   |  DW 3  |
OP_GETSTAT                |  71  (0x47)  |  G  |  DW 3  |
OP_INIT                         |  73  (0x49)  |  I   |   DW 3  |
OP_PRINT                     |   80  (0x50)  | P  |  DW 3  |
OP_READ                      |   82  (0x52)  | R  |  DW 3  |
OP_SETSTAT                |  83   (0x53)  | S  |  DW 3  |
OP_TERM                     |  84   (0x54)  | T  | DW 3  |
OP_WRITE                    |  87   (0x57)  | W  | DW 3  |
OP_DWINIT                   |  90   (0x5A)  | Z  | DW 4.0.0 |
OP_SERREADM            |  99   (0x63)  | c  | DW 4.0.0  |
OP_SERWRITEM           | 100  (0x64)  | d  | DW 4.0.0  |
OP_REREAD                 | 114   (0x72)  | r  | DW 3       |
OP_REWRITE                | 119   (0x77)  | w  | DW 3      |
OP_FASTWRITE_BASE  | 128  (0x80)   |    |  DW 4.0.0 |
OP_FASTWRITE_P1       | 129  (0x81)   |    |  DW 4.0.0 |
OP_FASTWRITE_P2       | 130  (0x82)   |    |  DW 4.0.0 |
OP_FASTWRITE_P3       | 131  (0x83)   |    |  DW 4.0.0 |
OP_FASTWRITE_P4       | 132  (0x84)   |    |  DW 4.0.0 |
OP_FASTWRITE_P5       |  133 (0x85)   |    |  DW 4.0.0 |
OP_FASTWRITE_P6       | 134  (0x86)   |    |  DW 4.0.0 |
OP_FASTWRITE_P7       | 135  (0x87)   |    |  DW 4.0.0 |
OP_FASTWRITE_P8       | 136  (0x88)   |    |  DW 4.0.0 |
OP_FASTWRITE_P9       | 137  (0x89)   |    |  DW 4.0.0 |
OP_FASTWRITE_P10     | 138  (0x8A)   |    |  DW 4.0.0 |
OP_FASTWRITE_P11      |  139 (0x8B)  |    |  DW 4.0.0 |
OP_FASTWRITE_P12     |  140  (0x8C)  |    |  DW 4.0.0 |
OP_FASTWRITE_P13     |  141  (0x8D)  |    |  DW 4.0.0 |
OP_FASTWRITE_P14     |  142  (0x8E)  |    |  DW 4.0.0 |
OP_FASTWRITE_P15     | 143   (0x8F)  |    |  DW 4.0.0  |
Reserved for future vserial use | 144-159 (0x90 - 0x9F) |  | N/A     |
OP_SERWRITE              |  195  (0xC3)  | C+128 | DW 4.0.0 |
OP_SERSETSTAT         |  196  (0xC4)  | D+128 | DW 4.0.0 |
OP_SERTERM              | 197   (0xC5)  | E+128 | DW 4.0.5 |
OP_READEX                | 210   (0xD2)  | R+128  | DW 3 |
OP_RFM                       | 214   (0xD6)  |  V+128 | Unofficial | See "Remote File Manager (RFM)" section |
OP_230K230K               | 230   (0xE6)  |            |  DW 4.0.0  | For 230k mode
OP_REREADEX            | 242   (0xF2)  | r+128   | DW 3 |
OP_RESET3                 | 248   (0xF8)  |            | DW 4.0.0 |
OP_230K115K               | 253   (0xFD)  |             | DW 4.0.0 | For 230k mode, detects bps switch
OP_RESET2                 | 254   (0xFE)  |             | DW 3  |
OP_RESET1                 | 255   (0xFF)  |             | DW 3  |





# Appendix D. Table of DW API command result codes
Result Code | Description
-------------------|----------
0                 | RC_SUCCESS
10 (0xA)      | RC_SYNTAX_ERROR
100 (0x64)   | RC_DRIVE_ERROR
101 (0x65)   | RC_INVALID_DRIVE
102 (0x66)   | RC_DRIVE_NOT_LOADED
103 (0x67)   | RC_DRIVE_ALREADY_LOADED
104 (0x68)   | RC_IMAGE_FORMAT_EXCEPTION
110 (0x6E)   | RC_NO_SUCH_DISKSET
111 (0x6F)   | RC_INVALID_DISK_DEF
120 (0x78)   | RC_NET_ERROR
121 (0x79)   | RC_NET_IO_ERROR
122 (0x7A)  | RC_NET_UNKNOWN_HOST
123 (0x7B)  | RC_NET_INVALID_CONNECTION
140 (0x8C)   | RC_INVALID_PORT
141 (0x8D)   | RC_INVALID_HANDLER
142 (0x8E)   | RC_CONFIG_KEY_NOT_SET
150 (0x96)   | RC_MIDI_ERROR
151 (0x97)   | RC_MIDI_UNAVAILABLE
152 (0x98)   | RC_MIDI_INVALID_DEVICE
153 (0x99)   | RC_MIDI_INVALID_DATA
154 (0x9A)   | RC_MIDI_SOUNDBANK_FAILED
155 (0x9B)   | RC_MIDI_SOUNDBANK_NOT_SUPPORTED
156 (0x9C)   | RC_MIDI_INVALID_PROFILE
200 (0xC8)   | RC_SERVER_ERROR
201 (0xC9)   | RC_SERVER_FILESYSTEM_EXCEPTION
202 (0xCA)  | RC_SERVER_IO_EXCEPTION
203 (0xCB)  | RC_SERVER_FILE_NOT_FOUND
204 (0xCC)  | RC_SERVER_NOT_IMPLEMENTED
205 (0xCD)  | RC_SERVER_NOT_READY
206 (0xCE)  | RC_INSTANCE_NOT_READY
220 (0xDC)  | RC_UI_ERROR
221 (0xDD)  | RC_UI_MALFORMED_REQUEST
222 (0xDE)  | RC_UI_MALFORMED_RESPONSE
230 (0xE6)  | RC_HELP_TOPIC_NOT_FOUND
255 (0xFF)  | RC_FAIL
