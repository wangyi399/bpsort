classdef BPSorter < handle
    
    properties %#ok<*PROP,*CPROP>
        TempDir             % temporary folder
        BlockSize           % size of blocks with constant waveform (sec)
        MaxSamples          % max number of samples to use
        HighPass            % highpass cutoff [stop, pass] (Hz)
        NyquistFreq         % Nyquist frequency (Hz)
        DropClusterThresh   % threshold for dropping clusters
    end
    
    
    properties (SetAccess = private)
        layout
        matfile
        Fs
        N
        K
    end
    
    
    methods
        
        function self = BPSorter(layout, varargin)
            % Constructor for BPSorter class
            
            p = inputParser;
            p.addOptional('TempDir', fullfile(tempdir(), datestr(now(), 'BP_yyyymmdd_HHMMSS')));
            p.addOptional('BlockSize', 60);
            p.addOptional('MaxSamples', 2e7);
            p.addOptional('HighPass', [400 600]);
            p.addOptional('NyquistFreq', 6000);
            p.addOptional('DropClusterThresh', 0.6);
            p.parse(varargin{:});
            par = fieldnames(p.Results);
            for i = 1 : numel(par)
                self.(par{i}) = p.Results.(par{i});
            end
            
            if isa(layout, 'Layout')
                self.layout = layout;
            else
                self.layout = Layout(layout);
            end
            self.K = self.layout.n;
            
            if ~exist(self.TempDir, 'file')
                mkdir(self.TempDir)
            else
                delete([self.TempDir '/*'])
            end
            
            self.Fs = 2 * self.NyquistFreq;
        end
        
        
        function delete(self)
            % Class destructor
            
            % remove temp directory
            delete(fullfile(self.TempDir, '*'))
            rmdir(self.TempDir)
        end
        
        
        function readData(self, br)
            % Read raw data, downsample and store in local temp file
            
            assert(self.K == getNbChannels(br), ...
                'Dataset and channel layout are incompatible: %d vs. %d channels!', ...
                getNbChannels(br), self.K)
            
            % create memory-mapped Matlab file
            dataFile = fullfile(self.TempDir, 'data.mat');
            save(dataFile, '-v7.3', 'dataFile'); % save something to create the file
            self.matfile = matfile(dataFile, 'writable', true);
            
            % read data, resample, and store to temp file
            Fs = getSamplingRate(self.baseReader);
            fr = filteredReader(self.baseReader, filterFactory.createHighpass(self.HighPass(1), self.HighPass(2), Fs));
            blockSize = round(self.BlockSize * Fs);
            pr = packetReader(fr, 1, 'stride', blockSize);
            [p, q] = rat(self.Fs / Fs);
            nBlocks = length(pr);
            lastBlockSize = ceil((length(fr) - (nBlocks - 1) * blockSize) * p / q);
            newBlockSize = ceil(blockSize * p / q);
            self.N = (nBlocks - 1) * newBlockSize + lastBlockSize;
            h5create(dataFile, '/V', [self.N self.K], 'ChunkSize', [newBlockSize self.K]);
            fprintf('Creating temporary file containing resampled data [%d blocks]\n%s\n', nBlocks, dataFile)
            for i = 1 : nBlocks
                if ~rem(i, 10)
                    fprintf('%d ', i)
                end
                V = toMuV(self.baseReader, resample(pr(i), p, q));
                start = (i - 1) * newBlockSize;
                self.matfile.V(start + (1 : newBlockSize), :) = V;
            end
            fprintf('done\n')
        end
        
        
        function initialize(self)
        end
        
    end
    
end
