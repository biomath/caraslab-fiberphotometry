function caraslab_preprocess_FPdata(Savedir, sel, T1, T2, set_new_trange)
% This function takes fiber photometry csv files and employs in this order:
% 1. Downsampling 10x by interpolation
% 2. Low-pass filter
% 3. Upsampling 10x by interpolation
% 4. Auto-detect LED onset by derivative
% 5. Fit 405 onto 465 and output df/f
% 4. Saves a filename_dff.csv file
%
%Input variables:
%
%       Savedir: path to folder containing data directories. Each directory
%                should contain a binary (-dat) data file and
%                a kilosort configuration (config.mat) file. 
%
%       sel:    if 0 or omitted, program will cycle through all folders
%               in the data directory.    
%
%               if 1, program will prompt user to select folder

%Written by M Macedo-Lima 10/05/20
if ~sel
    datafolders = caraslab_lsdir(Savedir);
    datafolders = {datafolders.name};

elseif sel  
    %Prompt user to select folder
    datafolders_names = uigetfile_n_dir(Savedir,'Select data directory');
    datafolders = {};
    for i=1:length(datafolders_names)
        [~, datafolders{end+1}, ~] = fileparts(datafolders_names{i});
    end
%     [~,name] = fileparts(pname);
%     datafolders = {name};  
%     
end


%For each data folder...
for i = 1:numel(datafolders)
    
    cur_path.name = datafolders{i};
    cur_savedir = fullfile(Savedir, cur_path.name);
    
    %Load in info file
    % Catch error if -mat file is not found
    try
        cur_infofiledir = dir(fullfile(cur_savedir, [cur_path.name '.info']));
        load(fullfile(cur_infofiledir.folder, cur_infofiledir.name), '-mat', 'epData');
    catch ME
        if strcmp(ME.identifier, 'MATLAB:load:couldNotReadFile')
            fprintf('\n-mat file not found\n')
            continue
        else
            fprintf(ME.identifier)
            fprintf(ME.message)
            continue
        end
    end
    fprintf('\n======================================================\n')
    fprintf('Processing and fitting photometry data, %s.......\n', cur_path.name)
    
    t0 = tic;
    
    % Create a configs variable to hold some info about the recording.
    % Optionally read a previously saved config to read info about T1 and
    % T2
    if set_new_trange
        ops = struct();
    else
        %Load in configuration file (contains ops struct)
        % Catch error if -mat file is not found
        try
            load(fullfile(cur_savedir, 'config.mat'));
        catch ME
            if strcmp(ME.identifier, 'MATLAB:load:couldNotReadFile')
                fprintf('\n-mat file not found\n')
                continue
            else
                fprintf(ME.identifier)
                fprintf(ME.message)
                continue
            end
        end        
    end
    
    % Load CSV file
    cur_datafiledir = dir(fullfile(cur_savedir, ['*' cur_path.name '_rawRecording.csv']));
    fullpath = fullfile(cur_datafiledir.folder, cur_datafiledir.name);
    cur_data = readtable(fullpath);
    fs = 1/mean(diff(cur_data.Time));
    
    ops.fraw = fullpath;
    ops.fs = fs;
    
    % Downsample, filter, upsample and normalize by isosbestic signal
    % Also interpolate time vector to keep timepoint numbers consistent
    % Add audio here too when needed
    y_465 = cur_data.Ch465_mV;
    y_405 = cur_data.Ch405_mV;
    time_vec = cur_data.Time;
    
    N = 10;
    y_465 = interp1(1:length(y_465), y_465, linspace(1,length(y_465), length(y_465)/N + 1));
    y_405 = interp1(1:length(y_405), y_405, linspace(1,length(y_405), length(y_405)/N + 1));
    time_vec = interp1(1:length(time_vec), time_vec, linspace(1,length(time_vec), length(time_vec)/N + 1));
    
    % Pad with "0"s to avoid filter artifacts
    padsize = 1000;
    y_465 = [repmat(y_465(:,1), [1 padsize]) y_465];
    y_405 = [repmat(y_405(:,1), [1 padsize]) y_405];
    
    lowpass = 5;
    [b1, a1] = butter(3, 2*lowpass/(fs/N), 'low'); % butterworth filter with only 3 nodes (otherwise it's unstable for float32)
    
    ops.lowpass = lowpass;
    
    % Filter then remove padding
    y_465 = filter(b1, a1, y_465');
    y_405 = filter(b1, a1, y_405');
    y_465 = y_465(padsize+1:end, :)'; 
    y_405 = y_405(padsize+1:end, :)';
    
    % upsample
    y_465 = interp1(1:length(y_465), y_465, linspace(1,length(y_465), length(y_465)*N + 1));
    y_405 = interp1(1:length(y_405), y_405, linspace(1,length(y_405), length(y_405)*N + 1));
    time_vec = interp1(1:length(time_vec), time_vec, linspace(1,length(time_vec), length(time_vec)*N + 1));

    % Detect LED onset via first-derivative > 1 and eliminate everything
    % from that point + 30 s
    % This was determined via visual inspection. Might need tweaking
    
    % Check if T1 and T2 already exist
    if ~set_new_trange
        if isfield(ops, 'T1')
            T1 = ops.T1;
        end
        if isfield(ops, 'T2')
            T2 = ops.T2;
        end
    end
        
    % Calculate T1 if T1 == 0
    if T1 == 0
        diff_thresh = 1;
        diff_465 = diff(y_465);
        crossing = find(diff_465 > diff_thresh, 1, 'first');
        % Eliminate from start until crossing + fs*30
        T1_idx = round(crossing + fs*10);
    else
        T1_idx = max([1, floor(T1*fs)]);
    end
    
    % Set T2 to whole recording if T2==Inf
    if T2 ~= Inf
        T2_idx = min(length(y_465), ceil(T2*fs));
    else
        T2_idx = length(time_vec);
    end
    
    % Save timeranges in case they changed
    new_T1 = T1_idx/fs;
    new_T2 = T2_idx/fs;
    ops.T1 = new_T1;
    ops.T2 = new_T2;    
    
    % Remove points before fitting
    y_465_offset = y_465(T1_idx:T2_idx);
    y_405_offset = y_405(T1_idx:T2_idx);
    time_vec_offset = time_vec(T1_idx:T2_idx);
    
    % Standardize signals
    y_405_offset = (y_405_offset - median(y_405_offset)) / std(y_405_offset);
    y_465_offset = (y_465_offset - median(y_465_offset)) / std(y_465_offset);
    
    % regress FP signal against 405 control to learn coeffs:
    % (if numerical problems, try subsampling data)
%     bls = polyfit(y_405_offset,y_465_offset,1);
%     Y_fit_all = bls(1) .* y_405_offset + bls(2);

    % using non negative robust linear regression
    bls = fit(y_405_offset', y_465_offset', fittype('poly1'),'Robust','on', 'lower', [0 -Inf]);
%     bls = fit(y_405_offset', y_465_offset', fittype('poly1'));
    Y_fit_all = bls(y_405_offset)';

    % Subtract Y_fit to get the residual 'transients' (in detector units,
    % i.e. Volts) then normalize by fit to get df/f for each timepoint
%     y_465_sub = (y_465_offset - Y_fit_all) ./ Y_fit_all * 100;
    y_465_sub = (y_465_offset - Y_fit_all);
    
    % Compile and save table
    datafilepath = split(cur_datafiledir.folder, filesep);
    subj_id = split(datafilepath{end-1}, '-');
    subj_id = join(subj_id(1:3), "-");
    datafilename = fullfile(cur_datafiledir.folder, [subj_id{1} '_' datafilepath{end}]);

    TT = array2table([time_vec_offset' y_465_offset' ... 
        y_405_offset' Y_fit_all' y_465_sub'],...
        'VariableNames',{'Time' 'Ch465_mV' 'Ch405_mV' 'Ch405_fit' 'Ch465_dff'});
    writetable(TT, [datafilename '_dff.csv']);    

    % Diagnostic Plots 
    color_405 = [179, 0, 179]/255;
    color_465 = [0, 128, 0]/255;
    
    close all;
    f = figure;

    % Raw recording plot
    subplot(3, 1, 1)
    plot(time_vec, y_405, 'color', color_405, 'LineWidth', 1); hold on;
    plot(time_vec, y_465, 'color', color_465, 'LineWidth', 1);
    line([time_vec(T1_idx) time_vec(T1_idx)], [0 1000], 'LineWidth', 2, 'LineStyle', ':', 'color', [179, 179, 255]/255);
    line([time_vec(T2_idx) time_vec(T2_idx)], [0 1000], 'LineWidth', 2, 'LineStyle', ':', 'color', [255, 102, 178]/255);
    
    % Finish up the plot
    axis tight
    xlabel('Time, s','FontSize',12)
    ylabel('mV', 'FontSize', 12)
    title(sprintf('Trial raw recording'))
    set(gcf, 'Position',[100, 100, 800, 500])
    
    % Make a legend
    legend('405 nm','465 nm','T1', 'T2', 'AutoUpdate', 'off');

    % 405-fit plot
    subplot(3, 1, 2)
    plot(time_vec_offset, Y_fit_all, 'color', color_405, 'LineWidth', 1);  hold on;
    plot(time_vec_offset, y_465_offset, 'color', color_465, 'LineWidth', 1);   
    % Finish up the plot
    axis tight
    xlabel('Time, s','FontSize',12)
    ylabel('mV', 'FontSize', 12)
    title(sprintf('Trial recording (405-fitted)'))
    set(gcf, 'Position',[100, 100, 800, 500])
    % Make a legend
%     legend('405 nm','465 nm','Onset', 'AutoUpdate', 'off');

    % 405-subtracted plot
    subplot(3, 1, 3)
    % Add AM trial events
    tt0_events = epData.epocs.TTyp.onset(epData.epocs.TTyp.data == 0);
    fill_YY = [min(y_465_sub), max(y_465_sub)];
    YY = repelem(fill_YY, 1, 2);
    fill_color = [163, 163, 194]/255;
    hold on;
    for event_idx=1:length(tt0_events)
        fill_XX = [tt0_events(event_idx) tt0_events(event_idx)+1];
        XX = [fill_XX, fliplr(fill_XX)];
        h = fill(XX, YY, fill_color);
        % Choose a number between 0 (invisible) and 1 (opaque) for facealpha.  
        set(h,'facealpha',.5,'edgecolor','none')
    end
    
    % Plot data on top
    plot(time_vec_offset, y_465_sub, 'color', color_465, 'LineWidth', 1); 
    
    % Finish up the plot
    axis tight
    xlabel('Time, s','FontSize',12)
    ylabel('dF/F %', 'FontSize', 12)
    title(sprintf('Trial recording (405-subtracted and drift-corrected)'))
    set(gcf, 'Position',[100, 100, 800, 500])
    
    % Make a legend
    legend('AM trial', 'AutoUpdate', 'off');
    
    % Save .fig and .pdf
    savefig(f, [datafilename '_trialPlot.fig'])
    set(gcf, 'PaperPositionMode', 'auto', 'renderer','Painters');
    print(gcf, '-painters', '-dpdf', '-r300', [datafilename '_recordingPlot'])

    %Save configuration file
    configfilename  = fullfile(cur_savedir,'config.mat');
    save(configfilename,'ops')
    fprintf('Saved configuration file: %s\n', configfilename)
    
    tEnd = toc(t0);
    fprintf('Done in: %d minutes and %f seconds\n', floor(tEnd/60), rem(tEnd,60));
    
end