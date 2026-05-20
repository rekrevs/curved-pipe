%NTB 2024
%Function to provide QR and Wmax
%

function [D,QR,maxW,r_maxW,maxPhi] = phi_updated_D_loop_QR_Wmax (D)

no_preamble_lines=7;

%D=10 %2000

D_str=int2str(D);
filename = ['updated_file_D' D_str '.dat'];
fid = fopen(filename);
textLine = fgets(fid); % Read first line.
lineCounter = 1;
while ischar(textLine)
  %  fprintf('\nLine #%d of text = %s\n', lineCounter, textLine);
  % get into numbers array.
  numbers = sscanf(textLine, '%f ');
  % Put numbers into a cell array IF and only if
  % you need them after the loop has exited.
  % First method - each number in one cell.
  for k = 1 : length(numbers)
    ca{lineCounter, k} = numbers(k);
  end
  % ALternate way where the whole array is in one cell.
  ca2{lineCounter} = numbers;

  % Read the next line.
    textLine = fgets(fid);
  lineCounter = lineCounter + 1;
end
fclose(fid);
% Display the cell arrays in the command line.
%ca
%ca2
NRP1=ca{1,1};
NAP1=ca{2,1};
XI=cell2mat(ca(3,1:4));
RHO=cell2mat(ca(4,1:3));
EPS=cell2mat(ca(5,1:3));
QR=ca{7,1};
%arrays
PHI=zeros(NRP1,NAP1);
W=zeros(NRP1,NAP1);
OMEGA=zeros(NRP1,NAP1);
%
temp1=size(ca);
ca_red=ca(no_preamble_lines+1:temp1(1),:);
temp2=size(ca_red);
rows_per_array=(temp2(1))/3;
ca_PHI=ca_red(1:rows_per_array,:);
ca_W= ca_red(rows_per_array+1:2*rows_per_array,:);
ca_OMEGA=ca_red(2*rows_per_array+1:3*rows_per_array,:);
%
PHI=cell2mat(ca_PHI);
W=cell2mat(ca_W);
OMEGA=cell2mat(ca_OMEGA);

r=0:1/(NRP1-1):1;
alpha=0:pi/(NAP1-1):pi;

[alpha_grid,r_grid]=meshgrid(alpha,r);
% Convert to Cartesian
x = r_grid.*cos(alpha_grid);
y = r_grid.*sin(alpha_grid);

%'Max phi:'
maxPhi = max(max(PHI));

%'Max W:'
maxW = max(max(W));
[x_maxW,y_maxW]=find(W==maxW);
%to handle D=10:
single_x_maxW = x_maxW(1);
single_y_maxW = y_maxW(1);
%
r_maxW = sqrt(x(single_x_maxW,single_y_maxW).^2+y(single_x_maxW,single_y_maxW).^2);
