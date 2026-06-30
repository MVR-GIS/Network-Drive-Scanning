#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <signal.h>

#define MAX_PATH_LENGTH 4096
#define FLUSH_INTERVAL 10

// Global counter for tracking progress
long long g_totalFiles = 0;
long long g_totalFolders = 0;
long long g_totalErrors = 0;
long long g_totalBytes = 0;
long long g_skippedHidden = 0;  // NEW: Track skipped hidden items
time_t g_startTime;
time_t g_lastUpdateTime;
int g_itemsSinceFlush = 0;
FILE* g_csvFile = NULL;
char g_lastPath[MAX_PATH_LENGTH] = "";

// Function to convert FILETIME to readable format
void FileTimeToString(FILETIME ft, char* buffer, size_t bufferSize) {
    SYSTEMTIME st;
    FILETIME localFileTime;
    
    if (FileTimeToLocalFileTime(&ft, &localFileTime) && 
        FileTimeToSystemTime(&localFileTime, &st)) {
        snprintf(buffer, bufferSize, "%04d-%02d-%02d %02d:%02d:%02d",
                 st.wYear, st.wMonth, st.wDay,
                 st.wHour, st.wMinute, st.wSecond);
    } else {
        snprintf(buffer, bufferSize, "1970-01-01 00:00:00");
    }
}

// Function to get file extension
void GetFileExtension(const char* filename, char* ext, size_t extSize) {
    if (!filename || !ext || extSize < 1) {
        if (ext) ext[0] = '\0';
        return;
    }
    
    const char* dot = strrchr(filename, '.');
    if (dot && dot != filename) {
        snprintf(ext, extSize, "%s", dot);
    } else {
        ext[0] = '\0';
    }
}

// Simplified CSV escape - just replace tabs and newlines
void EscapeCSVField(const char* input, char* output, size_t outputSize) {
    if (!input || !output || outputSize < 2) {
        if (output && outputSize > 0) output[0] = '\0';
        return;
    }
    
    size_t i, j = 0;
    for (i = 0; input[i] != '\0' && j < outputSize - 1; i++) {
        if (input[i] == '\t') {
            output[j++] = ' ';
        } else if (input[i] == '\n' || input[i] == '\r') {
            output[j++] = ' ';
        } else {
            output[j++] = input[i];
        }
    }
    output[j] = '\0';
}

void PrintProgress() {
    time_t now = time(NULL);
    int elapsed = (int)(now - g_startTime);
    int hours = elapsed / 3600;
    int minutes = (elapsed % 3600) / 60;
    int seconds = elapsed % 60;
    
    double gb = g_totalBytes / (1024.0 * 1024.0 * 1024.0);
    
    printf("\r[%02d:%02d:%02d] Files: %lld | Folders: %lld | Hidden: %lld | Errors: %lld | Size: %.2f GB    ", 
           hours, minutes, seconds, g_totalFiles, g_totalFolders, g_skippedHidden, g_totalErrors, gb);
    fflush(stdout);
}

void SaveCheckpoint() {
    if (g_csvFile) {
        fflush(g_csvFile);
    }
    
    // Save progress to a checkpoint file
    FILE* checkpoint = fopen("scan_checkpoint.txt", "w");
    if (checkpoint) {
        fprintf(checkpoint, "Last path: %s\n", g_lastPath);
        fprintf(checkpoint, "Files: %lld\n", g_totalFiles);
        fprintf(checkpoint, "Folders: %lld\n", g_totalFolders);
        fprintf(checkpoint, "Hidden skipped: %lld\n", g_skippedHidden);
        fprintf(checkpoint, "Errors: %lld\n", g_totalErrors);
        fprintf(checkpoint, "Bytes: %lld\n", g_totalBytes);
        fclose(checkpoint);
    }
}

// Write error to CSV
void WriteError(const char* path, const char* name, const char* errorMsg) {
    if (!g_csvFile || !path || !name || !errorMsg) return;
    
    char escapedPath[MAX_PATH_LENGTH];
    char escapedName[MAX_PATH_LENGTH];
    char escapedError[512];
    
    EscapeCSVField(path, escapedPath, sizeof(escapedPath));
    EscapeCSVField(name, escapedName, sizeof(escapedName));
    EscapeCSVField(errorMsg, escapedError, sizeof(escapedError));
    
    fprintf(g_csvFile, "%s\t%s\tError\t\t\t\t\t\tFailed\t%s\n",
            escapedPath, escapedName, escapedError);
    fflush(g_csvFile);
    
    g_totalErrors++;
}

// Recursive function to scan directory
void ScanDirectory(const char* dirPath, int depth) {
    WIN32_FIND_DATAW findData;
    HANDLE hFind = INVALID_HANDLE_VALUE;
    wchar_t searchPath[MAX_PATH_LENGTH];
    wchar_t wideDirPath[MAX_PATH_LENGTH];
    
    if (!dirPath) return;
    
    // Prevent infinite recursion
    if (depth > 50) {
        WriteError(dirPath, dirPath, "Max depth exceeded");
        return;
    }
    
    // Update last path for checkpoint
    strncpy(g_lastPath, dirPath, sizeof(g_lastPath) - 1);
    g_lastPath[sizeof(g_lastPath) - 1] = '\0';
    
    // Update progress
    time_t now = time(NULL);
    if (now - g_lastUpdateTime >= 1) {
        PrintProgress();
        SaveCheckpoint();
        g_lastUpdateTime = now;
    }
    
    // Convert to wide string
    if (MultiByteToWideChar(CP_ACP, 0, dirPath, -1, wideDirPath, MAX_PATH_LENGTH) == 0) {
        WriteError(dirPath, dirPath, "Path conversion failed");
        return;
    }
    
    // Build search path
    if (wcslen(wideDirPath) >= MAX_PATH_LENGTH - 3) {
        WriteError(dirPath, dirPath, "Path too long");
        return;
    }
    
    wcscpy(searchPath, wideDirPath);
    size_t pathLen = wcslen(searchPath);
    if (pathLen > 0 && searchPath[pathLen - 1] != L'\\') {
        wcscat(searchPath, L"\\");
    }
    wcscat(searchPath, L"*");
    
    hFind = FindFirstFileW(searchPath, &findData);
    
    if (hFind == INVALID_HANDLE_VALUE) {
        DWORD error = GetLastError();
        if (error != ERROR_FILE_NOT_FOUND) {
            char errorMsg[256];
            snprintf(errorMsg, sizeof(errorMsg), "FindFirstFile error %lu", error);
            WriteError(dirPath, dirPath, errorMsg);
        }
        return;
    }
    
    do {
        // Skip . and ..
        if (wcscmp(findData.cFileName, L".") == 0 || 
            wcscmp(findData.cFileName, L"..") == 0) {
            continue;
        }
        
        // NEW: Skip hidden files and folders
        if (findData.dwFileAttributes & FILE_ATTRIBUTE_HIDDEN) {
            g_skippedHidden++;
            continue;
        }
        
        char name[MAX_PATH_LENGTH];
        char fullPath[MAX_PATH_LENGTH];
        char parentPath[MAX_PATH_LENGTH];
        
        // Convert filename
        if (WideCharToMultiByte(CP_ACP, 0, findData.cFileName, -1, 
                                name, MAX_PATH_LENGTH, NULL, NULL) == 0) {
            continue;
        }
        
        // Build full path - be very careful here
        size_t dirLen = strlen(dirPath);
        size_t nameLen = strlen(name);
        
        if (dirLen + nameLen + 2 >= MAX_PATH_LENGTH) {
            WriteError(dirPath, name, "Path too long");
            continue;
        }
        
        strcpy(fullPath, dirPath);
        if (dirLen > 0 && fullPath[dirLen - 1] != '\\') {
            strcat(fullPath, "\\");
        }
        strcat(fullPath, name);
        
        strcpy(parentPath, dirPath);
        if (dirLen > 0 && parentPath[dirLen - 1] != '\\') {
            strcat(parentPath, "\\");
        }
        
        // Get timestamps
        char created[64];
        char modified[64];
        FileTimeToString(findData.ftCreationTime, created, sizeof(created));
        FileTimeToString(findData.ftLastWriteTime, modified, sizeof(modified));
        
        // Escape fields
        char escapedFullPath[MAX_PATH_LENGTH];
        char escapedName[MAX_PATH_LENGTH];
        char escapedParent[MAX_PATH_LENGTH];
        
        EscapeCSVField(fullPath, escapedFullPath, sizeof(escapedFullPath));
        EscapeCSVField(name, escapedName, sizeof(escapedName));
        EscapeCSVField(parentPath, escapedParent, sizeof(escapedParent));
        
        if (findData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            // Directory
            g_totalFolders++;
            
            if (g_csvFile) {
                fprintf(g_csvFile, "%s\t%s\tFolder\t\t\t%s\t%s\t%s\tSuccess\t\n",
                        escapedFullPath, escapedName, created, modified, escapedParent);
                
                g_itemsSinceFlush++;
                if (g_itemsSinceFlush >= FLUSH_INTERVAL) {
                    fflush(g_csvFile);
                    g_itemsSinceFlush = 0;
                }
            }
            
            // Recurse
            ScanDirectory(fullPath, depth + 1);
            
        } else {
            // File
            g_totalFiles++;
            
            ULONGLONG fileSize = ((ULONGLONG)findData.nFileSizeHigh << 32) | 
                                 findData.nFileSizeLow;
            g_totalBytes += fileSize;
            
            char extension[256];
            GetFileExtension(name, extension, sizeof(extension));
            
            char escapedExt[256];
            EscapeCSVField(extension, escapedExt, sizeof(escapedExt));
            
            if (g_csvFile) {
                fprintf(g_csvFile, "%s\t%s\tFile\t%s\t%llu\t%s\t%s\t%s\tSuccess\t\n",
                        escapedFullPath, escapedName, escapedExt, fileSize, 
                        created, modified, escapedParent);
                
                g_itemsSinceFlush++;
                if (g_itemsSinceFlush >= FLUSH_INTERVAL) {
                    fflush(g_csvFile);
                    g_itemsSinceFlush = 0;
                }
            }
        }
        
    } while (FindNextFileW(hFind, &findData) != 0);
    
    if (hFind != INVALID_HANDLE_VALUE) {
        FindClose(hFind);
    }
}

// Signal handler for Ctrl+C
void SignalHandler(int signal) {
    printf("\n\nInterrupted by user. Saving...\n");
    SaveCheckpoint();
    if (g_csvFile) {
        fflush(g_csvFile);
        fclose(g_csvFile);
    }
    printf("Progress saved to scan_checkpoint.txt\n");
    exit(0);
}

int main(int argc, char* argv[]) {
    char outputPath[MAX_PATH_LENGTH];
    char inputPath[MAX_PATH_LENGTH];
    char fullInputPath[MAX_PATH_LENGTH];
    
    // Set up signal handler
    signal(SIGINT, SignalHandler);
    signal(SIGTERM, SignalHandler);
    
    if (argc < 2) {
        printf("Usage: %s <directory_path> [output_csv_file]\n", argv[0]);
        printf("Example: %s \"S:\\\" output.csv\n", argv[0]);
        return 1;
    }
    
    // Get full path
    DWORD result = GetFullPathNameA(argv[1], MAX_PATH_LENGTH, fullInputPath, NULL);
    if (result == 0 || result >= MAX_PATH_LENGTH) {
        printf("ERROR: Cannot resolve path '%s'\n", argv[1]);
        return 1;
    }
    
    strncpy(inputPath, fullInputPath, sizeof(inputPath) - 1);
    inputPath[sizeof(inputPath) - 1] = '\0';
    
    // Remove trailing backslash
    size_t len = strlen(inputPath);
    if (len > 3 && inputPath[len - 1] == '\\') {
        inputPath[len - 1] = '\0';
    }
    
    // Output file
    if (argc >= 3) {
        snprintf(outputPath, sizeof(outputPath), "%s", argv[2]);
    } else {
        snprintf(outputPath, sizeof(outputPath), "directory_listing.csv");
    }
    
    printf("===========================================\n");
    printf("Directory Scanner - GCC Edition\n");
    printf("===========================================\n");
    printf("Input: %s\n", inputPath);
    printf("Output: %s\n", outputPath);
    printf("Checkpoint: scan_checkpoint.txt\n");
    printf("Hidden files: SKIPPED\n");
    printf("===========================================\n\n");
    
    // Check directory
    DWORD attribs = GetFileAttributesA(inputPath);
    if (attribs == INVALID_FILE_ATTRIBUTES) {
        printf("ERROR: Cannot access '%s'\n", inputPath);
        return 1;
    }
    
    if (!(attribs & FILE_ATTRIBUTE_DIRECTORY)) {
        printf("ERROR: '%s' is not a directory\n", inputPath);
        return 1;
    }
    
    printf("Starting scan of 124 TB drive...\n");
    printf("This will take a VERY long time.\n");
    printf("Press Ctrl+C to stop safely.\n\n");
    
    // Open CSV
    g_csvFile = fopen(outputPath, "w");
    if (!g_csvFile) {
        printf("ERROR: Cannot create '%s'\n", outputPath);
        return 1;
    }
    
    // Write header
    fprintf(g_csvFile, "FullPath\tName\tType\tExtension\tSizeBytes\tCreated\tModified\tParentPath\tStatus\tErrorMessage\n");
    fflush(g_csvFile);
    
    // Initialize
    g_totalFiles = 0;
    g_totalFolders = 0;
    g_totalErrors = 0;
    g_totalBytes = 0;
    g_skippedHidden = 0;
    g_startTime = time(NULL);
    g_lastUpdateTime = g_startTime;
    g_itemsSinceFlush = 0;
    
    // Scan
    ScanDirectory(inputPath, 0);
    
    fclose(g_csvFile);
    g_csvFile = NULL;
    
    // Final stats
    printf("\n\n");
    time_t endTime = time(NULL);
    int totalSeconds = (int)(endTime - g_startTime);
    int hours = totalSeconds / 3600;
    int minutes = (totalSeconds % 3600) / 60;
    int seconds = totalSeconds % 60;
    
    double totalGB = g_totalBytes / (1024.0 * 1024.0 * 1024.0);
    double totalTB = totalGB / 1024.0;
    
    printf("===========================================\n");
    printf("Scan Complete!\n");
    printf("===========================================\n");
    printf("Files:       %lld\n", g_totalFiles);
    printf("Folders:     %lld\n", g_totalFolders);
    printf("Hidden:      %lld (skipped)\n", g_skippedHidden);
    printf("Errors:      %lld\n", g_totalErrors);
    printf("Total size:  %.2f TB (%.2f GB)\n", totalTB, totalGB);
    printf("Time:        %02d:%02d:%02d\n", hours, minutes, seconds);
    printf("Output:      %s\n", outputPath);
    printf("===========================================\n");
    
    return 0;
}