# Summary:

The code in this repository scans network drives and extracts data from those scans for analysis -- especially image data.

Not all folders or files here are organized. They are here for development purposes. The latest iteration of our scanning efforts is in the "C++ Scanning" folder.

## C++ Scanning Documentation

The C++ scanner is a single file, file_curser.cpp. It must be compiled into a .exe file to use it. We are using the GNU C Compiler. It takes arguments of a folder path to search and a file name to store the output in. The output is in CSV format, so use of .csv file extension is recommended.

### Instructions
These instructions cover downloading the .cpp file, obtaining a C++ compiler, adding the C++ compiler to the system PATH, compiling the .cpp code, and running the program.

#### Downloading the file
- Navigate to the "C++ Scanning" folder and click on the file_curser.cpp. Click the download icon on the top right of the file.
- Place it in a known folder to locate the file and to handle output files later.

#### Obtaining a compiler
- Download the MSYS2 installer from https://www.msys2.org/
- Run the installer
- In the "Installation Folder" section, choose a folder in your user directory, example: "C:\Users\b5abcdef\Programs\msys64" (you may have to create some of these folders).
- Finish msys2 installation and open msys2
- Change drives to the C: drive with `cd C:`
- update the MSYS2 environment with `pacman -Syu`
- Install gcc with `pacman -S mingw-w64-c86_64-gcc`
- Verify install with `/mingw64/bin/gcc --version`. If details about the compiler are generated, the compiler is installed correctly.

#### Adding Compiler to PATH
- In the Windows search bar, type "path"
- Select the option that says "Edit environment variables for your account"
- Under "user variables", select the "Path" variable and click "Edit"
- Enter the path of the GCC, or the GNU C Compiler we installed. It should be in the path where msys2 is installed, and then in /mingw64/bin. Example: "C:\Users\b5abcdef\Programs\msys64\mingw64\bin"
- Click "ok" and "ok" 
- Verify correct path addition by opening a command line and running `gcc --version`.
- *Your C++ compiler is now accessible from anywhere on the machine*

#### Compiling the .cpp File
- Open a command line and navigate to the directory where the file_curser.cpp file is stored.
- run `gcc file_curser.cpp -o file_curser.exe`
- *You now have file_curser.exe and can run the program*
#### Running the program
The program takes two arguments: a root file path to search, and an output file name. This is an example command:
`./file_curser.exe "\\mvr-netapp1\egis" EGISoutput.csv`

This runs the file_cursor.exe with a root directory of the mvr-netapp1\egis drive and stores the output in EGISoutput.csv.
