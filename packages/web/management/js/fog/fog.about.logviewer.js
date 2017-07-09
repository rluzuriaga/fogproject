var LogToView;
var LinesToView;
var LogTimer;
var logdata;
$(function() {
    LogToView = $('#logToView').val();
    LinesToView = $('#linesToView').val();
    LogGetData();
    $("input[name='reverse']:checkbox").change(LogGetData);
    $('#logpause').on('click', function(e) {
        if ($(this).hasClass('activenow')) {
            $(this).removeClass('activenow').text('Pause');
            LogGetData();
        } else {
            $(this).addClass('activenow').text('Continue');
            clearTimeout(LogTimer);
        }
        e.preventDefault();
    });
    $('#logToView, #linesToView').on('change', function(e) {
        LogToView = $('#logToView').val();
        LinesToView = $('#linesToView').val();
        if ($('#logpause').hasClass('activenow')) {
            $('#logpause').removeClass('activenow').text('Pause');
        }
        LogGetData();
        e.preventDefault();
    });
})
function LogGetData() {
    if ($('#logpause').hasClass('activenow')) {
        return;
    }
    splitUs = LogToView.split('||');
    ip = splitUs[0];
    file = splitUs[1];
    reverse = $('[name=reverse]').is(':checked') ? 1 : 0;
    $.post(
        '../status/logtoview.php',
        {
            ip: ip,
            file: file,
            lines: LinesToView,
            reverse: reverse
        },
        displayLog,
        'json'
    ).done(function() {
        $('#logsGoHere').html(
            '<div class="panel panel-info">'
            + '<div class="panel-heading text-center">'
            + '<h4 class="title">'
            + file
            + '</h4>'
            + '</div>'
            + '<div class="panel-body">'
            + logdata
            + '</div>'
            + '</div>'
        );
        LogTimer = setTimeout(LogGetData,10000)
    });
}
function displayLog(data) {
    logdata = '<pre>'
        + data
        + '</pre>';
}
