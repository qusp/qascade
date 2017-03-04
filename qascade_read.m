function [filesMapToKeyValues, issues] = qascade_read(folder, parentKeyValues, fileMatcheDirectives, rootFolder, issues)
filesMapToKeyValues = containers.Map; % file keys are the (file: (key:value)) pairs.

if ~exist(folder, 'dir')
    error('Input folder does not exist');
end;

if ~exist('issues', 'var')
    issues = Issues;
end;

if exist('parentKeyValues', 'var')
    folderKeys = parentKeyValues; % folder keys are the (key:value) pairs that are common to all files in the folder.
else
    folderKeys = newEmptyMap;
end;

if ~exist('fileMatcheDirectives', 'var')
    fileMatcheDirectives = newEmptyMap;
end;

% make sure that folder variable does not have a file separator (since we do not want double file
% separators anywhere)
if folder(end) == filesep
    folder = folder(1:(end-1));
end;

if ~exist('rootFolder', 'var')
    rootFolder = folder;
end;

manifestFileName = 'manifest.qsc.yaml';


% get the list of files and folders
d = dir(folder);
d(1:2) = [];
names = {d.name};
subfolderMask = [d.isdir];

subfolders = names(subfolderMask);
files = names(~subfolderMask);


% look for the manifest file in the folderm exlude it from the list of files, and process it.
id = strcmp(files, manifestFileName);
if any(id)
    files(id) = []; % remove the manifest from the list of payload files.
    newFolderKeyValues = ReadYamlRawMap([folder filesep manifestFileName]);
else
    newFolderKeyValues = newEmptyMap;
end;

[filesMapToKeyValues, folderKeys, fileMatcheDirectives, onlyThisFolderKeys] = process_manifest_keys(folder, rootFolder, files, newFolderKeyValues, filesMapToKeyValues,...
 folderKeys, fileMatcheDirectives, manifestFileName, issues);

% add file keys for the subfolder
for i=1:length(subfolders)
    % copyMap is because container.Map is a handle class, hence
    % sending it inside a function can change its value
    
    newFileKeys = qascade_read([folder filesep subfolders{i}], copyMap(folderKeys), fileMatcheDirectives, rootFolder, issues);
    filesMapToKeyValues = [filesMapToKeyValues; newFileKeys];
end;

if nargin == 1 && issues.existsAny
    issues.show;
end
end
%%


function [filesMapToKeyValues, folderKeyValues, fileMatcheDirectives, onlyThisFolderKeys] = process_manifest_keys(folder, rootFolder, files, ...
newFolderKeyValues, filesMapToKeyValues, folderKeyValues, fileMatcheDirectives, manifestFileName, issues)

matchDirective = 'matches';
tableDirective = 'table';
noSubfolderDirective = 'no-subdir';

onlyThisFolderKeys = newEmptyMap;

% overwrite keys by the ones present in the manifest file
keys = newFolderKeyValues.keys;

for i = 1:length(keys)
    if ~isempty(regexp(keys{i}, ['^(' matchDirective '.*\)$'], 'once')) %  ^ in the beginning indices that it has to start with [, $ indicates that it has to end with ]
        matchPattern = keys{i}((length(matchDirective)+3):(end-1));
        if isKey(fileMatcheDirectives, matchPattern)
            fileMatcheDirectives(matchPattern) = [fileMatcheDirectives(matchPattern); newFolderKeyValues(keys{i})];
        else
            fileMatcheDirectives(matchPattern) = newFolderKeyValues(keys{i});
        end;
    elseif ~isempty(regexp(keys{i}, ['^(' tableDirective '.*\)$'], 'once')) %  ^ in the beginning indices that it has to start with [, $ indicates that it has to end with ]
        % table name is not important
        
        % write to a temporary file and use readtable to import as tsv file
        tempFileName = [tempname '.txt'];
        fid = fopen(tempFileName, 'w');
        fprintf(fid, newFolderKeyValues(keys{i}));
        fclose(fid);
        
        try
            warning('off', 'MATLAB:table:ModifiedVarnames');
            tble = readtable(tempFileName,'Delimiter','\t','ReadVariableNames',true);
            tbleNoVariableNames = readtable(tempFileName,'Delimiter','\t','ReadVariableNames',false); % used to  read unmodified variable names
            warning('on', 'MATLAB:table:ModifiedVarnames');
            delete(tempFileName);
            keyNames = tbleNoVariableNames{1,:};
            if strcmp(keyNames{1}, '(matches)') 
                for j=1:height(tble)
                    map = newEmptyMap;
                    
                    for k=2:width(tble) % extract key:value pairs from the tabel, into a map,then assign that map to the match pattern in fileMatcheDirectives.
                        value = tble{j,k};
                        if ischar(value)
                            switch value % because outside of the table, YAML reader converts 'true' to 1 and 'false' to 0
                                case 'true'
                                    value = 1;
                                case 'false'
                                    value = 0;
                            end;
                        end;
                        map(keyNames{k}) = value;
                    end;
                    matchPattern = cell2mat(tble{j, 'x_matches_'});
                    if isKey(fileMatcheDirectives, matchPattern)
                        fileMatcheDirectives(matchPattern) = [fileMatcheDirectives(matchPattern); map];
                    else
                        fileMatcheDirectives(matchPattern) = map;
                    end;
                    
                end;
            else
                issues.addError(sprintf('Error: The the table specified in key ''%s'' of file %s does not have ''(matches)'' as its first column header.', keys{i}, [folder filesep manifestFileName]));
            end
        catch e
            issues.addError(sprintf('The the table specified in key ''%s'' of file %s is malformed (is not tab-separated and/or have a different number of columns at different rows).', keys{i}, [folder filesep manifestFileName]));
        end;
    elseif ~isempty(regexp(keys{i}, ['^(' noSubfolderDirective '.*\)$'], 'once')) %  ^ in the beginning indices that it has to start with [, $ indicates that it has to end with ]
        onlyThisFolderKeys = newFolderKeyValues(keys{i});
    else        
        folderKeyValues = addExtendedKeyToMap(folderKeyValues, keys{i}, newFolderKeyValues(keys{i}), [folder filesep manifestFileName], issues);
    end;    
end

if ~isempty(onlyThisFolderKeys)
    [onlyThisFolderFilekeys, onlyThisFolderFolderKeys, folderOnlyFileMatcheDirectives, onlyThisFolderKeys] = process_manifest_keys(folder, rootFolder, files, onlyThisFolderKeys, copyMap(filesMapToKeyValues)...
        , copyMap(folderKeyValues), copyMap(fileMatcheDirectives), manifestFileName, issues);
end;

% add file keys for the current folder
for i=1:length(files)
    filesMapToKeyValues([folder filesep files{i}]) = folderKeyValues;
end;

% apply file match directives (overwrite keys for files matching certain wildcard expressions)
keys = fileMatcheDirectives.keys;
for i=1:length(keys)
    
    % create full paths but exclude the root folder so it is not used in pattern matching (this
    % makes the container portable)
   % fullPaths = strcat([folder((length(rootFolder)+1):end) filesep], files);    
   % matchIds = find(~cellfun(@isempty, regexp(fullPaths, regexptranslate('wildcard', keys{i})))); % match the full file path, including the name.
     
  % unclear whether relative folder matching works
    fullPaths = strcat([folder filesep], files);
    if keys{i}(end) ==  '/' % if it end with / then it is anywhere (under the root of the container)
        [list, isDir] = glob([rootFolder filesep '**' keys{i}]);
    else % if it starts with / then it is relative to the manifest folder
        [list, isDir] = glob([folder filesep keys{i}]);
    end;
    matchIds = ismember(fullPaths, list(~isDir));
    
    if any(strcmp(folder, list(isDir))) || any(strcmp([folder filesep], list(isDir)))
        matchIds(:) = true;
    end;
    matchIds = find(matchIds);
   % assert(isequal(matchIds_old, matchIds));
    
    % overwrite keys when a file name matched wildcard
    for j=1:length(matchIds)
        filename = [folder filesep files{matchIds(j)}];
        %filesMapToKeyValues(filename) = [filesMapToKeyValues(filename); fileMatcheDirectives(keys{i})];
        
          filesMapToKeyValues(filename) = addExtendedMapToMap(filesMapToKeyValues(filename), fileMatcheDirectives(keys{i}),...
              [folder filesep manifestFileName], issues);
    end;
    
end;

% add folder-only filesMapToKeyValues last so they take precedence over matches and other keys
if exist('onlyThisFolderFilekeys', 'var')
    keys = onlyThisFolderFilekeys.keys;
    for i=1:length(keys)
        filesMapToKeyValues(keys{i}) = [filesMapToKeyValues(keys{i}); onlyThisFolderFilekeys(keys{i})];
    end;
end;

end


function map = addExtendedMapToMap(map, newMap, manifestFile, issues)
keys = newMap.keys;
map = copyMap(map);
for i =1:length(keys)
    map = addExtendedKeyToMap(map, keys{i}, newMap(keys{i}), manifestFile, issues);
end;
end

%%
function map = addExtendedKeyToMap(map, key, value, manifestFile, issues)
% adds a (key:value) pair to the map, while interpreting key.field.field.. diectives.

if any(key == '.') % the key contains one or more dots, indicating that it could be a subfield overwrite directive
    parts = strsplit(key, '.');
    newMap = nestedKeyOverwrite(map, parts, value, parts(1), manifestFile, issues);
    map = [map; newMap];   
else
    map(key) = value;
end;
end

%%
function newMap = nestedKeyOverwrite(map, parts, value, partsTravelled, manifestFile, issues)
% newMap = nestedKeyOverwrite(map, parts)
% overwrites keys specied in 'parts' in the (nested) map.
% If keys are not present at a level, a map is created at that level (equates to creating a MATLAB
% structurewith only the specified field and subfields);

lastKey = length(parts) == 1;

if ~exist('partsTravelled', 'var')
    partsTravelled = {};
end

keyExists = isKey(map, parts{1});

newMap = copyMap(map);

if lastKey && keyExists
    newMap(parts{1}) = value;
elseif lastKey && ~keyExists
    newMap(parts{1}) = value;
elseif ~lastKey && keyExists
    partsTravelled{end+1} = parts{2};
    nextLevel = map(parts{1});
    if isa(nextLevel, 'containers.Map')
        newMap(parts{1}) = nestedKeyOverwrite(nextLevel, parts(2:end), value, partsTravelled, manifestFile, issues);
    else
        issues.addWarning(sprintf('In file %s: ''%s'' overwrite cannot be applied because ''%s'' (the parent key) is not a structure (multi-field entity).', manifestFile,...
            strjoin_adjoiner_first('.', partsTravelled), strjoin_adjoiner_first('.', partsTravelled(1:end-1))));
    end;
elseif ~lastKey && ~keyExists
    partsTravelled{end+1} = parts{2};
    newMap(parts{1})= nestedKeyOverwrite(newEmptyMap, parts(2:end), value, partsTravelled, manifestFile, issues);
end;

end

%%

function newMap = copyMap(map)
% makes a new 'copy by value' copy of the map so e.g. changes inside a function does not affect the
% map variable outside

if isempty(map)
    newMap = newEmptyMap;
else
    newMap = containers.Map(map.keys, map.values, 'UniformValues', false);
end;
end

function map = newEmptyMap
map = containers.Map('UniformValues', false);
end