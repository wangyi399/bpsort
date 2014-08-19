% Spike sorting using binary pursuit.
%
% Implements the algorithm described in the following paper: 
% Pillow, Shlens, Chichilnisky & Simoncelli (2013): A Model-Based Spike
% Sorting Algorithm for Removing Correlation Artifacts in Multi-Neuron
% Recordings. PLoS ONE 8, e62123.
%
% AE 2014-08-07

classdef BP
    properties %#ok<*PROP>
        window      % window for extracting waveform: [a b] ms
        samples     % samples corresponding to waveform window
        Fs          % sampling rate
        verbose     % verbose output during fitting?
        tempFiltLen % length of temporal whitening filter (ms)
        upsamplingFactor  % upsampling factor for spike times
        pruning     % pruning threshold for subset selection on waveforms
        passband    % passband of continuous input signal
        D           % # dimensions
    end
    
    methods
        
        function self = BP(varargin)
            % BP constructor
            %   bp = BP('param1', value1, 'param2', value2, ...) constructs
            %   a BP object with the following optional parameters:
            %
            %   window: 1x2 vector specifying the time window (ms) to
            %       extract waveforms (peak = 0; default [-0.5 1])
            %   Fs: sampling rate (Hz)
            %   verbose: true|false
            %   tempFiltLen: length of filter for temporal whitening
            %       (default = 0.7 ms)
            %   upsamplingFactor: upsampling factor used for spike
            %       detection (default = 5)
            %   pruning: constant applied for subset selection when
            %       estimating waveforms (default = 1)
            %   passband: passband of the continuous input signal (default:
            %       [600 15000] / Nyquist)
            
            % parse optional parameters
            p = inputParser;
            p.KeepUnmatched = true;
            p.addOptional('window', [-1 1.5]);
            p.addOptional('Fs', 12000);
            p.addOptional('verbose', false);
            p.addOptional('tempFiltLen', 0.7);
            p.addOptional('upsamplingFactor', 5, @(p) assert(mod(p, 2) == 1, 'Upsampling factor must be odd!'));
            p.addOptional('pruning', 1);
            p.addOptional('passband', [0.6 15] / 16);
            p.parse(varargin{:});
            self.window = p.Results.window;
            self.Fs = p.Results.Fs;
            self.samples = round(self.window(1) * self.Fs / 1000) : round(self.window(2) * self.Fs / 1000);
            self.D = numel(self.samples);
            self.verbose = p.Results.verbose;
            self.tempFiltLen = p.Results.tempFiltLen;
            self.upsamplingFactor = p.Results.upsamplingFactor;
            self.pruning = p.Results.pruning;
            self.passband = p.Results.passband;
        end
        
        
        function [X, W] = fit(self, V, X, iter)
            % Fit model (i.e. estimate waveform templates and spike times).
            %   [X, W] = self.fit(V, X0) fits the model to waveforms V
            %   using the initial spike sorting results X0.
            %
            %   [X, W] = self.fit(V, X0, iter) uses the specified number of
            %   iterations to fit the parameters (default = 3).
            %
            %   INPUTS
            %
            %   V       Continuous voltage signal
            %           T-by-K      T: number of time bins
            %                       K: number of channels
            %
            %   X0      Initial spike sorting result (sparse matrix, where
            %           X_ij=1 indicates a spike at sample i and neuron j)
            %           T-by-M      M: number of clusters
            %
            %   iter    Number of iterations to run
            %
            %
            %   OUTPUTS
            %
            %   X       Spike times (same format as input X0)
            %
            %   W       Array of waveforms 
            %           D-by-K-by-M     D: number of samples
            %                           K: number of channels
            %                           M: number of neurons

            if nargin < 4
                iter = 3;
            end
            for i = 1 : iter
                W = self.estimateWaveforms(V, X);
                R = self.residuals(V, X, W);
                Vw = self.whitenData(V, R);
                Ww = self.estimateWaveforms(Vw, X, self.pruning);
                X = self.estimateSpikes(Vw, X, Ww);
            end
            W = self.estimateWaveforms(V, X);
        end
        
        
        function W = estimateWaveforms(self, V, X, pruning)
            % Estimate waveform templates given spike times.
            %   W = self.estimateWaveforms(V, X) estimates the waveforms W
            %   given the observed voltage V and the current estimate of
            %   the spike times X.
            %
            %   W = self.estimateWaveforms(V, X, pruning) applies subset
            %   selection on the waveforms using the given pruning factor
            %   (multiples of the noise amplitude).
            
            [T, K] = size(V);
            M = size(X, 2);
            D = numel(self.samples);
            [i, j, x] = find(X);
            x = x - 1;
            d = 2 * (x > 0) - 1;
            i = [i; i + d];
            i = bsxfun(@plus, i, self.samples);
            valid = i > 0 & i <= T;
            j = bsxfun(@plus, (j - 1) * D, 1 : D);
            j = [j; j];
            x = repmat([1 - abs(x); abs(x)], 1, D);
            MX = sparse(i(valid), j(valid), x(valid), T, D * M);
            W = (MX' * MX) \ (MX' * V);
            W = reshape(W, [D M K]);
            W = permute(W, [1 3 2]);
            
            % subset selection of waveforms
            if nargin > 3 && pruning > 0
                W(:, sqrt(sum(W .^ 2, 1)) < pruning) = 0;
            end
        end
        
        
        function V = whitenData(self, V, R)
            % Whiten data.
            %   V = self.whitenData(V, R) whitens the data V, assuming
            %   that the spatio-temporal covariance separates into a
            %   spatial and a temporal component. Whitening filters are
            %   estimated from the residuals R.

            % determine frequencies outside the passband to avoid
            % amplification of those frequencies
            q = round(self.tempFiltLen / 1000 * self.Fs);
            k = 4 * q + 1;
            F = linspace(0, 2, k + 1);
            F = F(1 : end - 1);
            high = find(F > self.passband(2) & F < 2 - self.passband(2));
            low = F < self.passband(1) | F > 2 - self.passband(1);
            U = dftmtx(k);
            
            % temporal whitening
            for i = 1 : size(V, 2)
                
                % construct filter for temporal whitening
                c = xcorr(R(:, i), 2 * q, 'coeff');
                c = ifftshift(c);
                ci = 1./ abs(fft(c));
                if ~isempty(high)
                    ci(high) = ci(high(1) - 1);
                end
                ci(low) = 0;
                w = real(U * (sqrt(ci) .* U(2 * q + 1, :)') / k);
                w = w(q + 1 : end - q);

                % apply temporal whitening filter
                V(:, i) = conv(V(:, i), w, 'same');
                R(:, i) = conv(R(:, i), w, 'same');
            end
            
            % spatial whitening
            V = V * chol(inv(cov(R)))';
        end
        
        
        function V = residuals(self, V, X, W)
            % Compute residuals by subtracting waveform templates.
            %   R = self.residuals(V, X, W) computes the residuals by
            %   subtracting the model prediction X * W from the data V.
            
            for i = 1 : size(X, 2)
                spikes = find(X(:, i));
                for j = 1 : numel(spikes)
                    r = X(spikes(j), i) - 1;
                    s = sign(r);
                    V(spikes(j) + self.samples, :) = V(spikes(j) + self.samples, :) - (1 - abs(r)) * W(:, :, i);
                    V(spikes(j) + self.samples + s, :) = V(spikes(j) + self.samples + s, :) - abs(r) * W(:, :, i);
                end
            end
        end
        
        
        function Xn = estimateSpikes(self, V, X, W)
            % Estimate spike times given waveform templates.
            %   X = self.estimateSpikes(V, X, W) estimates the spike times
            %   given the current estimate of the waveforms using binary
            %   pursuit.

            % initialize \Delta L (Eq. 9) assuming X = 0 (no spikes)
            [T, K] = size(V);
            p = sum(X > 0, 1) / T;
            gamma = log(1 - p) - log(p);
            ww = permute(sum(sum(W .^ 2, 1), 2) / 2, [1 3 2]);
            DL = 0;
            for k = 1 : K
                Wk = permute(W(:, k, :), [1 3 2]);
                DL = DL + conv2(V(:, k), flipud(Wk));
            end
            DL = DL(self.samples(end) + (1 : T), :);
            DL = bsxfun(@minus, DL, gamma + ww);
            
            % pre-compute updates to \Delta L needed when flipping X_ij
            p = self.upsamplingFactor;
            D = self.D;
            s = 1 - D : D - 1;
            M = size(X, 2);
            dDL = zeros((2 * D) * p, M, M);
            for i = 1 : M
                for j = 1 : M
                    for k = 1 : K
                        dDL(:, i, j) = dDL(:, i, j) + conv(upsample([0; flipud(W(:, k, i))], p), resample(W(:, k, j), p, 1));
                    end
                end
            end
            
            % greedy search for flips with largest change in posterior
            win = gausswin(4 * p + 1, 3.5);
            win = win / sum(win) * p;
            Xn = greedy(sparse(T, M), DL, dDL, s, 1 - s(1), T - s(end) + s(1) - 1, p, win);
        end
    end
end


function [X, DL] = greedy(X, DL, dDL, s, offset, T, up, win)
    % [X, DL] = greedy(X, DL, dDL, offset, T) performs a greedy search for
    %   flips with largest change in posterior. We use a divide & conquer
    %   approach, splitting the data at the maximum and recursively
    %   processing each chunk, thus speeding up the maximum search
    %   substantially.
    
    Tmax = 10000;
    if T > Tmax
        % divide & conquer: split at current maximum
        [X, DL, i] = flip(X, DL, dDL, s, offset, T, up, win);
        if ~isnan(i)
            [X, DL] = greedy(X, DL, dDL, s, offset, i - offset, up, win);
            [X, DL] = greedy(X, DL, dDL, s, i, T - i + offset, up, win);
        end
    else
        % regular loop greedily searching maximum
        i = 0;
        while ~isnan(i)
            [X, DL, i] = flip(X, DL, dDL, s, offset, T, up, win);
        end
    end
end


function [X, DL, i] = flip(X, DL, dDL, s, offset, T, up, win)
    % [m, i, j] = findmax(DL, offset, T) finds the maximum change of the
    %   log-posterior (DL) achieved by inserting or removing a spike in the
    %   interval DL(offset + (1 : T), :) and returns indices i and j.
    
    ns = numel(s) - 1;
    [m, ndx] = max(reshape(DL(offset + (1 : T), :), [], 1));
    if m > 0
        i = offset + rem(ndx - 1, T) + 1;
        j = ceil(ndx / T);
        if ~X(i, j)
            % add spike - subsample
            pad = (numel(win) - 1) / up / 2 + 1;
            dl = upsample(DL(i + (-pad : pad), j), up);
            dl = conv(dl(ceil(up / 2) + 1 : end - ceil(up / 2)), win, 'valid');
            [~, r] = max(dl);
            r = (r - fix(up / 2) - 1) / up;
            X(i, j) = 1 + r; % > 1 => shift right, < 1 => shift left
        else
            % remove spike
            r = X(i, j) - 1;
            X(i, j) = 0;
        end
        DLij = DL(i, j);
        sub = up + 1 - round(r * up);
        DL(i + s, :) = DL(i + s, :) - (2 * (X(i, j) > 0) - 1) * dDL(sub + (0 : ns) * up, :, j);
        DL(i, j) = -DLij;
    else
        i = NaN;
    end
end


function y = upsample(x, k)
    % y = upsample(x, up) up-samples vector x k times by inserting zeros.
    
    n = numel(x);
    y = zeros((n - 1) * k + 1, 1);
    y((0 : n - 1) * k + 1) = x;
end

